#!/usr/bin/env node
//
//  test-xaca-1005-001-escaper-breakouts.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * Regression coverage for XACA-1005-001: escaper-context defects in
 * lcars-ui/js/lcars.js, all found while hand-verifying the same defect class
 * as part of the XACA-1005 escaper audit. (XACA-1005-022 — this header was
 * previously stale, still describing round 1's "four hand-verified" count
 * after four more rounds landed; corrected here to the actual final scope.)
 *
 * CURRENT SCOPE, five rounds, all in ONE commit because they are the same
 * root cause (no escaper, or the wrong one, at an interpolation site) found
 * across the same audit pass — see CHANGELOG.md for the full approval trail
 * and per-site/per-finding reasoning; this header summarizes, it does not
 * duplicate:
 *   Round 1 (original scope):  SITE 1 — crTitle (renderReleaseCard).
 *   Round 2 (folded in):       SITE 2 — epic selector (showEpicAssignModal,
 *                              JS-string-literal, arbitrary JS execution);
 *                              SITES 3/4/5 — merge-dialog title (jsAttrEscape
 *                              x2, escapeAttr x1).
 *   Round 3 (folded in):       SITES 6/7 — calendar day items
 *                              (renderDayItems): epic-branch titleText,
 *                              kanban-branch item.title + priorityClass.
 *   Round 4 (folded in):       FINDINGS A/B/C — renderDayItems()'s row2
 *                              (element content), external-event branch
 *                              (dead code, hardened anyway), epicBadge.
 *   Round 5 (PR #795 gate —    a same-class site (epic-badge truncateTitle())
 *   this round):               left unescaped one line below a fixed site,
 *                              PLUS its external-event sibling; a behaviour
 *                              regression the row2 fix introduced (falsy vs
 *                              nullish empty-guard mismatch on numeric `0`);
 *                              undercounted dueDate sinks in showMergeDialog();
 *                              a bare data-epic-id in showEpicAssignModal()
 *                              no ticket enumerated. See the file's own
 *                              per-round test sections below for detail on
 *                              each.
 *
 * Everything else in lcars.js remains explicitly OUT of scope — a separate
 * audit of ~86 other candidates is tracked under other XACA-1005 subitems
 * and is NOT touched here. server.py is explicitly out of scope for this
 * whole ticket (a mass-assignment gap is filed separately as XACA-1020; an
 * item.id/epic.id defense-in-depth pass is filed separately as XACA-1013).
 *
 * THREE ESCAPERS, THREE CONTEXTS. escapeHtml() is textContent -> innerHTML;
 * per the WHATWG fragment-serialization spec it escapes `&`, U+00A0, `<`,
 * `>` and DELIBERATELY LEAVES QUOTES ALONE. escapeAttr() (lcars.js ~11504)
 * additionally escapes `"` and `'` to `&quot;`/`&#39;` — the right escaper
 * for a plain QUOTED HTML ATTRIBUTE, and a safe superset of escapeHtml() in
 * element content (the entities decode back to the same literal character
 * either way, so there is no visual difference — see the crTitle site below
 * for the full argument). jsAttrEscape() (lcars.js ~11558) additionally
 * escapes `\` and `'` with JS-STRING escapes (`\\`, `\'`) rather than HTML
 * entities — the right, and ONLY correct, escaper when the value lands
 * inside a JS STRING LITERAL that is itself embedded in an HTML attribute
 * (e.g. `onclick="fn('${...}')"`.  escapeAttr() would be WRONG there: it
 * would render a hostile `'` as `&#39;`, which the BROWSER's HTML-attribute
 * parser decodes back to a literal `'` before the JS engine ever sees it —
 * the escaping happens at the wrong layer and the string literal still
 * breaks. jsAttrEscape() would equally be wrong for a plain attribute
 * value (SITE 5 below): it renders `'` as `\'`, a literal backslash-quote,
 * which is wrong for an <input> whose value the user reads back verbatim.
 * A uniform swap to any one escaper across all four sites below is wrong;
 * each is justified individually at its own site and in the commit message.
 *
 * === SITE 1 (original scope) — crTitle, QUOTED-ATTRIBUTE breakout ===
 * `renderReleaseCard()`'s linked-CR chip (~11244) renders
 *
 *     <button ... title="Navigate to CR: ${crTitle}">${crIdEsc} — ${crTitle}</button>
 *
 * `crTitle` lands inside the QUOTED `title="..."` attribute AND as element
 * content. It was escapeHtml()'d for both. A CR title of
 * `Fix " onmouseover=alert(1) x="` — CR titles are user-supplied, verified
 * against live board data — closed the attribute early and injected a live
 * `onmouseover=` attribute onto the `<button>`. Same shape XACA-0416 found
 * across five other client apps. Fixed: escapeAttr() for BOTH
 * interpolations (safe superset in element content — see the THREE
 * ESCAPERS note above). `crIdEsc` is interpolated once, as element content
 * only, never in an attribute — left on escapeHtml().
 *
 * === SITE 2 (folded-in, HIGHEST SEVERITY) — epic selector, JS-STRING-LITERAL
 * breakout, arbitrary JS execution ===
 * `showEpicAssignModal()`'s epic-option chip (~13890) renders
 *
 *     onclick="selectEpicForItem('${epic.id}', '${escapeHtml(epic.title || epic.name)}')"
 *
 * `epic.id` was interpolated RAW (no escaper at all); `epic.title` used
 * escapeHtml(), which leaves BOTH `'` and `\` untouched. `epic.title` is
 * user-supplied — traced to lcars-ui/server.py's epic-creation POST handler,
 * which assigns the request body's `name` straight to the `title` field
 * with no sanitization (`epic['title'] = post_data['name']`). An epic
 * titled `'); alert(1); //` closes the JS string literal INSIDE the
 * onclick value and the browser executes `alert(1)` — no HTML attribute
 * breakout is even needed, since the payload contains no `"`. This is a
 * strictly worse outcome than SITE 1's attribute injection: arbitrary JS
 * execution versus an injected attribute. Fixed: jsAttrEscape() for BOTH
 * epic.id and epic.title||epic.name — same JS-string-literal slot, same
 * escaper, regardless of which field is server-assigned vs free-text; the
 * SINK determines the escaper, not the field's provenance.
 *
 * === SITES 3 & 4 (folded-in) — merge-dialog suggestion buttons, SAME
 * JS-STRING-LITERAL breakout class as SITE 2 ===
 * `showMergeDialog()` (~8189) renders two buttons:
 *
 *     onclick="document.getElementById('merge-title').value = '${escapeHtml(localTitle)}'"
 *     onclick="document.getElementById('merge-title').value = '${escapeHtml(externalTitle)}'"
 *
 * `localTitle`/`externalTitle` are read back via `.textContent` from
 * `renderConflictItem()`'s already-rendered markup — the browser decodes any
 * entities on the way out, so these locals are plain text again by the time
 * they reach this NEW sink; the earlier render's escaping does not carry
 * over. `localVersion` is this client's own kanban item data;
 * `externalVersion` (traced to `GET /api/calendar/conflicts`) is the
 * external calendar sync feed — outside this app's trust boundary. Both
 * get the same fix because the sink, not the source, decides the escaper.
 * Fixed: jsAttrEscape() for both, same reasoning as SITE 2.
 *
 * === SITE 5 (folded-in) — merge-dialog title input, QUOTED-ATTRIBUTE
 * breakout, SAME CLASS AS SITE 1 ===
 * The same `showMergeDialog()` also renders
 *
 *     <input type="text" id="merge-title" value="${escapeHtml(localTitle)}" />
 *
 * A plain quoted attribute, not a JS string literal — escapeAttr() is
 * correct here, NOT jsAttrEscape(): jsAttrEscape() would render a genuine
 * apostrophe in a real title as a literal `\'` in the input's value,
 * corrupting what the user sees and would save. Getting this distinction
 * right against SITES 3/4 (same function, adjacent lines, different
 * escaper) is the point of this ticket.
 *
 * WHY A NEW FILE, NOT test-xaca-1000-release-archive-platform-set.js. That
 * sibling file already extracts and exercises `renderReleaseCard()` (for the
 * PROMOTE/EDIT/DELETE/ARCHIVE controls) using the exact same brace-matching
 * extraction technique used below, and reusing its harness was considered.
 * Declined so this ticket's diff stays single-purpose and independently
 * cherry-pickable: touching that file would also require renumbering its
 * already-adopted `SUITES` floor in lcars-ui-js-suite.yml for an unrelated
 * ticket's assertions, and creates an avoidable merge surface against the
 * concurrent XACA-1005 audit work in a sibling worktree.
 *
 * lcars-ui/js/lcars.js is a large browser file with top-level DOM calls and no
 * jsdom/jest harness in this repo (matching every sibling suite in this
 * directory), so this test does NOT `require()` it. It extracts individual
 * pure/DOM-lite functions by brace-matching from the `function NAME(` (or
 * `async function NAME(`) declaration and evaluates them against small,
 * purpose-built DOM/fetch stubs — the identical technique
 * test-xaca-1000-release-archive-platform-set.js uses for `renderReleaseCard()`
 * — so the extracted functions are exactly what ships, not a reimplementation.
 *
 * ANTI-VACUITY. Every claim below is a NEGATIVE/POSITIVE control pair:
 *   - A fixture reproducing the OLD (wrong-escaper) shape must still
 *     demonstrate the breakout — proves the assertions can fail, and proves
 *     the vulnerability class is real, not hypothetical.
 *   - A fixture using the correct escaper must stay clean — proves the
 *     checks do not just flag everything.
 *   - The REAL, freshly-extracted shipped function — which reads whatever is
 *     currently in lcars.js at test-run time — is run through the SAME
 *     assertions for SITE 1 (renderReleaseCard), SITE 2
 *     (showEpicAssignModal) and SITES 3/4/5 (showMergeDialog). Run against
 *     the pre-fix source, each block fails identically to its OLD-shape
 *     fixture; after the fix each passes identically to its correct-escaper
 *     fixture. That is the "fails before, passes after" proof for the
 *     ACTUAL shipped code, not a simulation of it.
 *   - A source-level regex additionally pins each assignment/interpolation
 *     statement to its correct escaper, so a future template refactor that
 *     escapes the functional checks above cannot silently regress the
 *     escaper choice without this failing loudly.
 *
 * Run:
 *   node lcars-ui/tests/test-xaca-1005-001-escaper-breakouts.js
 */

'use strict';

const fs = require('fs');
const path = require('path');

const LCARS_JS_PATH = path.join(__dirname, '..', 'js', 'lcars.js');
const source = fs.readFileSync(LCARS_JS_PATH, 'utf8');

let failures = 0;

function fail(msg) {
    failures++;
    console.error(`FAIL: ${msg}`);
}

function check(name, actual, expected) {
    if (actual === expected) {
        console.log(`ok - ${name}`);
    } else {
        fail(`${name} — expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
    }
}

/**
 * Extract a top-level `function NAME(...) { ... }` by brace matching.
 *
 * Matches test-xaca-1000-release-archive-platform-set.js's `extractFunction`
 * verbatim in behaviour: bounded by the declaration itself (not two textual
 * landmarks, which would silently widen if code is inserted between them),
 * and parameter-list-aware (a default value that is itself an object literal
 * — e.g. `{}`  — must not be mistaken for the function body's opening brace).
 * Throws rather than returning empty if the function is renamed or removed,
 * so this test fails loudly instead of silently checking nothing.
 */
function extractFunction(name) {
    const needle = `\nfunction ${name}(`;
    const start = source.indexOf(needle);
    if (start === -1) {
        throw new Error(
            `could not locate 'function ${name}(' in lcars-ui/js/lcars.js — ` +
            `it may have been renamed, removed, or turned into an expression. ` +
            `Update this test to match.`
        );
    }
    const parenOpen = source.indexOf('(', start);
    let parenDepth = 0;
    let parenClose = -1;
    for (let i = parenOpen; i < source.length; i++) {
        const ch = source[i];
        if (ch === '(') parenDepth++;
        else if (ch === ')') {
            parenDepth--;
            if (parenDepth === 0) { parenClose = i; break; }
        }
    }
    if (parenClose === -1) {
        throw new Error(`unbalanced parens while locating ${name}'s parameter list`);
    }
    const bodyStart = source.indexOf('{', parenClose);
    let depth = 0;
    for (let i = bodyStart; i < source.length; i++) {
        const ch = source[i];
        if (ch === '{') depth++;
        else if (ch === '}') {
            depth--;
            if (depth === 0) return source.slice(start + 1, i + 1);
        }
    }
    throw new Error(`unbalanced braces while extracting ${name}`);
}

/**
 * Like extractFunction, but for an `async function NAME(...) { ... }`
 * declaration (showEpicAssignModal is async — it awaits fetch()). The needle
 * differs only by the `async ` prefix; including it in the needle means
 * `start + 1` naturally captures "async function ..." onward, so the
 * re-assembled source below is still a syntactically valid async function
 * declaration (dropping "async" would make its `await` a SyntaxError).
 */
function extractAsyncFunction(name) {
    const needle = `\nasync function ${name}(`;
    const start = source.indexOf(needle);
    if (start === -1) {
        throw new Error(
            `could not locate 'async function ${name}(' in lcars-ui/js/lcars.js — ` +
            `it may have been renamed, removed, or had 'async' dropped. ` +
            `Update this test to match.`
        );
    }
    const parenOpen = source.indexOf('(', start);
    let parenDepth = 0;
    let parenClose = -1;
    for (let i = parenOpen; i < source.length; i++) {
        const ch = source[i];
        if (ch === '(') parenDepth++;
        else if (ch === ')') {
            parenDepth--;
            if (parenDepth === 0) { parenClose = i; break; }
        }
    }
    if (parenClose === -1) {
        throw new Error(`unbalanced parens while locating ${name}'s parameter list`);
    }
    const bodyStart = source.indexOf('{', parenClose);
    let depth = 0;
    for (let i = bodyStart; i < source.length; i++) {
        const ch = source[i];
        if (ch === '{') depth++;
        else if (ch === '}') {
            depth--;
            if (depth === 0) return source.slice(start + 1, i + 1);
        }
    }
    throw new Error(`unbalanced braces while extracting ${name}`);
}

let escapeAttr;
let jsAttrEscape;
let truncateTitle;
let isReleaseComplete;
let getIncompletePlatforms;
let getPlatformName;
let renderArchiveAction;
let getReleaseEnvironments;
let buildItemTagsHtml;
let renderReleaseCard;
let formatTargetDate;
let parseLocalDate;
let formatDate;

try {
    const slices = [
        extractFunction('escapeAttr'),
        extractFunction('jsAttrEscape'),
        extractFunction('truncateTitle'),
        extractFunction('isReleaseComplete'),
        extractFunction('getIncompletePlatforms'),
        extractFunction('getPlatformName'),
        extractFunction('renderArchiveAction'),
        extractFunction('getReleaseEnvironments'),
        extractFunction('buildItemTagsHtml'),
        extractFunction('parseLocalDate'),
        extractFunction('formatTargetDate'),
        extractFunction('formatDate'),
        extractFunction('renderReleaseCard'),
    ].join('\n\n');

    // escapeHtml() is DOM-backed (textContent -> innerHTML) and cannot run in
    // bare Node, so — matching test-xaca-1000-release-archive-platform-set.js
    // exactly — it gets a faithful DOM-free equivalent covering the four
    // characters the WHATWG fragment-serialization spec actually escapes for
    // text content (&, <, >; U+00A0 is not exercised by any fixture here).
    //
    // No `document`/`window` stub is needed: every release fixture below
    // omits `tags`, so `buildItemTagsHtml` short-circuits on its
    // `!Array.isArray(tags) || tags.length === 0` guard before it would ever
    // call `document.createElement` — the same precondition test-xaca-1000's
    // suite documents and relies on for the same reason.
    //
    // formatTargetDate/parseLocalDate ARE now extracted (6th round, PR #795
    // gate) — a prior version of this comment said "every release fixture
    // below omits ... targetDate, so formatTargetDate is never reached",
    // which was true until this round's fixture set `release.targetDate` to
    // exercise formatTargetDate()'s own catch-and-return-raw bug (the same
    // shape as formatDate()'s, found while checking whether that shape is a
    // CLASS). Omitting these two here would leave formatTargetDate
    // undefined inside `renderReleaseCard`'s `new Function` scope, throwing
    // a ReferenceError the moment any fixture sets a truthy targetDate — the
    // exact same missing-extraction bug already caught once for escapeAttr
    // in the SITE-2 factory.
    const preamble = 'function escapeHtml(t) { if (!t) return ""; return String(t)' +
        '.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }\n' +
        'var CANONICAL_STAGES = ["DEV", "QA", "ALPHA", "BETA", "GAMMA", "PROD"];\n' +
        'var releasesState = { expandedReleases: new Set() };\n';

    // eslint-disable-next-line no-new-func
    const factory = new Function(
        preamble + slices +
        '\nreturn { escapeAttr, jsAttrEscape, truncateTitle, isReleaseComplete, getIncompletePlatforms,' +
        ' getPlatformName, renderArchiveAction, getReleaseEnvironments, buildItemTagsHtml,' +
        ' parseLocalDate, formatTargetDate, formatDate, renderReleaseCard };'
    );
    ({
        escapeAttr,
        jsAttrEscape,
        truncateTitle,
        isReleaseComplete,
        getIncompletePlatforms,
        getPlatformName,
        renderArchiveAction,
        getReleaseEnvironments,
        buildItemTagsHtml,
        parseLocalDate,
        formatTargetDate,
        formatDate,
        renderReleaseCard,
    } = factory());
} catch (e) {
    console.error(`FAIL: ${e.message}`);
    process.exit(1);
}

/** Locate a `<button class="EXACT">...` tag and return its outer opening markup. */
function extractButtonTag(html, exactClassAttr) {
    const marker = 'class="' + exactClassAttr + '"';
    const markerIdx = html.indexOf(marker);
    if (markerIdx === -1) return null;
    const tagStart = html.lastIndexOf('<button', markerIdx);
    const tagEnd = html.indexOf('>', markerIdx);
    if (tagStart === -1 || tagEnd === -1) return null;
    return html.slice(tagStart, tagEnd + 1);
}

/**
 * Full `<button class="EXACT">...content...</button>` element, tag + content.
 * Deliberately a separate helper from extractButtonTag (which stops at the
 * opening tag's `>`): the CR chip's element-content interpolation of crTitle
 * is only visible in the content, not the opening tag.
 */
function extractButtonElement(html, exactClassAttr) {
    const marker = 'class="' + exactClassAttr + '"';
    const markerIdx = html.indexOf(marker);
    if (markerIdx === -1) return null;
    const tagStart = html.lastIndexOf('<button', markerIdx);
    const closeIdx = html.indexOf('</button>', markerIdx);
    if (tagStart === -1 || closeIdx === -1) return null;
    return html.slice(tagStart, closeIdx + '</button>'.length);
}

/**
 * `name="([^"]*)"` deliberately stops at the FIRST raw double quote. That is
 * not a limitation here — it is the instrument. If a hostile `"` survives
 * unescaped inside the attribute value, this regex truncates the captured
 * value right there, exactly mirroring what a real HTML parser does to the
 * attribute boundary itself.
 */
function getAttr(tag, name) {
    const m = tag && tag.match(new RegExp(name + '="([^"]*)"'));
    return m ? m[1] : null;
}

// A CR title containing a raw double quote, immediately followed by an
// attacker-controlled attribute assignment and a trailing quote-balancing
// tail — the exact shape named in this ticket. CR titles are user-supplied,
// verified against live board data.
const HOSTILE_CR_TITLE = 'Fix " onmouseover=alert(1) x="';
const HOSTILE_CR_ID = 'CR-1005';

function releaseWithCr(crTitle) {
    return {
        id: 'REL-CR-1005-TEST',
        name: 'CR Chip Escaping Test Release',
        status: 'active',
        platforms: { other: { environment: 'DEV' } },
        linkedCRs: [{ crId: HOSTILE_CR_ID, crTitle }],
    };
}

/**
 * The shared assertion set, run against three different sources of the CR
 * chip's `<button>` markup below: an OLD-shape fixture (must fail), an
 * escapeAttr-shape fixture (must pass), and the REAL renderReleaseCard()
 * output (must pass, because that is what ships).
 *
 * `mustBreakOut` flips the expected outcome so the exact same assertions
 * serve as both the negative control (breakout expected) and the positive
 * controls (no breakout expected) — the property under test does not change,
 * only which shape is being fed to it.
 */
function assertCrTitleAttributeShape(label, tag, mustBreakOut) {
    if (!tag) {
        fail(`${label}: no <button class="release-cr-link"> tag to inspect`);
        return;
    }
    const titleMatch = tag.match(/title="([^"]*)"/);
    check(`${label}: a title attribute is present`, !!titleMatch, true);
    if (!titleMatch) return;
    const titleAttr = titleMatch[1];

    // If the hostile raw quote survived unescaped, the regex above (like
    // getAttr's) truncates the captured value right there — the tail "x="
    // never makes it into titleAttr. Escaped, the whole string (rendered as
    // &quot; instead of a raw quote) survives and "x=" is present.
    check(`${label}: title attribute text is ${mustBreakOut ? 'TRUNCATED at' : 'NOT truncated by'} the hostile raw quote`,
        titleAttr.indexOf('x=') !== -1, !mustBreakOut);

    // The structural proof: did the hostile payload become a LIVE, SEPARATE
    // attribute on the tag, or stay inert text INSIDE title="..."? Naively
    // grepping the whole tag for "onmouseover=" is the WRONG test here — that
    // substring is present, inertly, as text inside a correctly-escaped
    // title value too (only the quote characters are escaped; the word
    // "onmouseover=" is untouched either way). So strip the matched
    // title="..." SEGMENT (quotes and all, using titleMatch's own extent)
    // out of the tag first, then check what remains. When the attribute
    // closed properly, the whole hostile payload — onmouseover= included —
    // is inside that stripped segment and nothing remains. When it broke
    // out, the regex above stopped at the injected quote, so the segment it
    // matched is short and the genuine ` onmouseover=alert(1) x="..."` tail
    // is left behind in the remainder for this check to find.
    const tagWithoutTitle = tag.slice(0, titleMatch.index) + tag.slice(titleMatch.index + titleMatch[0].length);
    check(`${label}: onmouseover= ${mustBreakOut ? 'becomes' : 'does NOT become'} a live attribute on the tag (checked OUTSIDE the title="..." value)`,
        /\bonmouseover\s*=/.test(tagWithoutTitle), mustBreakOut);

    if (!mustBreakOut) {
        check(`${label}: the hostile quote is present as the &quot; entity, not raw`,
            /&quot;/.test(titleAttr), true);
        check(`${label}: title attribute value contains no raw double quote`,
            titleAttr.indexOf('"') === -1, true);
    }
}

// ---------------------------------------------------------------------------
// NEGATIVE CONTROL: reproduce the OLD (pre-XACA-1005-001) escapeHtml-in-
// attribute shape as a standalone fixture and prove it actually breaks out.
// This is what a "fix that is right by coincidence" would fail to show.
// ---------------------------------------------------------------------------

function buildOldVulnerableCrButton(crId, crTitleRaw) {
    // OLD shape: escapeHtml() used for BOTH interpolations of crTitle.
    const crIdSafe = jsAttrEscape(crId);
    const crTitle = escapeHtml(crTitleRaw);
    const crIdEsc = escapeHtml(crId);
    return `<button class="release-cr-link" onclick="event.stopPropagation(); navigateToReleaseCR('${crIdSafe}')" title="Navigate to CR: ${crTitle}">${crIdEsc} — ${crTitle}</button>`;
}
// escapeHtml is defined only inside the `new Function` factory scope above
// (it is deliberately NOT exported — it is the vulnerable/DOM-free stand-in,
// not part of the API under test), so re-declare the identical faithful
// stand-in here for this standalone fixture builder.
function escapeHtml(t) {
    if (!t) return ''; return String(t).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

// openingTagOnly mirrors what extractButtonTag returns for the LIVE test
// below (the opening `<button ...>` only, no element content). Required so
// this check is not contaminated by the button's VISIBLE TEXT, which also
// legitimately contains the inert substring "onmouseover=" as part of
// `${crTitle}` in `${crIdEsc} — ${crTitle}` — that occurrence is harmless
// text either way and must not be mistaken for a live attribute.
function openingTagOnly(fullElementHtml) {
    return fullElementHtml.slice(0, fullElementHtml.indexOf('>') + 1);
}

const oldTag = openingTagOnly(buildOldVulnerableCrButton(HOSTILE_CR_ID, HOSTILE_CR_TITLE));
assertCrTitleAttributeShape('NEGATIVE CONTROL (pre-fix escapeHtml-in-attribute shape)', oldTag, /* mustBreakOut */ true);

// ---------------------------------------------------------------------------
// POSITIVE CONTROL: the same template, escapeAttr() in place of escapeHtml()
// for crTitle — proves the check discriminates rather than flagging everything.
// ---------------------------------------------------------------------------

function buildFixedCrButton(crId, crTitleRaw) {
    const crIdSafe = jsAttrEscape(crId);
    const crTitle = escapeAttr(crTitleRaw);
    const crIdEsc = escapeHtml(crId);
    return `<button class="release-cr-link" onclick="event.stopPropagation(); navigateToReleaseCR('${crIdSafe}')" title="Navigate to CR: ${crTitle}">${crIdEsc} — ${crTitle}</button>`;
}

const fixedTag = openingTagOnly(buildFixedCrButton(HOSTILE_CR_ID, HOSTILE_CR_TITLE));
assertCrTitleAttributeShape('POSITIVE CONTROL (escapeAttr-in-attribute shape)', fixedTag, /* mustBreakOut */ false);

// ---------------------------------------------------------------------------
// THE ACTUAL SHIPPED CODE. renderReleaseCard() was extracted fresh from
// lcars-ui/js/lcars.js at the top of this file — this block proves the LIVE
// site, not a simulation of it. Run against the pre-fix source, this section
// fails exactly like the NEGATIVE CONTROL above; after XACA-1005-001, it
// passes exactly like the POSITIVE CONTROL.
// ---------------------------------------------------------------------------

const realHtml = renderReleaseCard(releaseWithCr(HOSTILE_CR_TITLE));
const realCrTag = extractButtonTag(realHtml, 'release-cr-link');
assertCrTitleAttributeShape('LIVE renderReleaseCard()', realCrTag, /* mustBreakOut */ false);

// Element-content check: crIdEsc/crTitle also appear once each as
// `${crIdEsc} — ${crTitle}` inside the button's visible text. escapeAttr's
// output there must still render identically to escapeHtml's — verified by
// checking the hostile quote reaches the content as the &quot; entity (which
// the browser's HTML parser decodes back to a literal `"` character exactly
// as escapeHtml's raw-quote-left-alone approach would have displayed it) and
// that no stray `<`/`>` slipped through.
const realCrElement = extractButtonElement(realHtml, 'release-cr-link');
check('LIVE renderReleaseCard(): CR chip element (button) was located', !!realCrElement, true);
if (realCrElement) {
    const content = realCrElement.slice(realCrElement.indexOf('>') + 1, realCrElement.lastIndexOf('</button>'));
    check('LIVE renderReleaseCard(): element content carries the hostile quote as &quot;, not raw',
        /&quot;/.test(content), true);
    check('LIVE renderReleaseCard(): element content contains no raw double quote',
        content.indexOf('"') === -1, true);
    check('LIVE renderReleaseCard(): element content is not truncated (full hostile payload present via "x=")',
        content.indexOf('x=') !== -1, true);
}

// A SECOND, differently-shaped release (no linkedCRs at all) must still
// render cleanly — the fix must not have broken the common case where the
// chip section is entirely absent.
const plainHtml = renderReleaseCard({
    id: 'REL-CR-1005-PLAIN', name: 'No CRs Release', status: 'active',
    platforms: { other: { environment: 'DEV' } },
});
check('LIVE renderReleaseCard(): a release with no linkedCRs renders no CR chip section',
    plainHtml.indexOf('release-linked-crs') === -1, true);

// ---------------------------------------------------------------------------
// SOURCE-LEVEL LOCK. Defense in depth beyond the functional checks above: pin
// the crTitle assignment statement itself to escapeAttr on BOTH branches, so
// a later refactor of renderReleaseCard's template shape — which could make
// the functional checks above stop exercising this exact statement — cannot
// silently regress the escaper choice without this failing loudly.
// ---------------------------------------------------------------------------

const crTitleAssignment = source.match(
    /const crTitle\s*=\s*entry\.crTitle\s*\?\s*(\w+)\(entry\.crTitle\)\s*:\s*(\w+)\(entry\.crId \|\| ''\);/
);
check('source: crTitle assignment statement located in lcars.js (renderReleaseCard\'s linked-CR chip builder)',
    !!crTitleAssignment, true);
if (crTitleAssignment) {
    check('source: crTitle (entry.crTitle branch) uses escapeAttr — it lands in a quoted title= attribute',
        crTitleAssignment[1], 'escapeAttr');
    check('source: crTitle (entry.crId fallback branch) uses escapeAttr too, for the same attribute-context reason',
        crTitleAssignment[2], 'escapeAttr');
}

// crIdEsc must stay on escapeHtml — it is never used in an attribute — but
// pin THAT too, so a future "helpfully" upgrade to escapeAttr for both
// variables is at least a deliberate, reviewed choice rather than an
// unnoticed drift the moment someone next edits this block.
const crIdEscAssignment = source.match(/const crIdEsc\s*=\s*entry\.crId\s*\?\s*(\w+)\(entry\.crId\)\s*:\s*'';/);
check('source: crIdEsc assignment statement located in lcars.js',
    !!crIdEscAssignment, true);
if (crIdEscAssignment) {
    check('source: crIdEsc uses escapeHtml (element-content only, never an attribute — confirmed by the checks above)',
        crIdEscAssignment[1], 'escapeHtml');
}


// ===========================================================================
// SITE 2 (folded-in scope expansion, HIGHEST SEVERITY) — epic selector
// JS-STRING-LITERAL breakout in showEpicAssignModal(), arbitrary JS execution.
// ===========================================================================
//
// `selectEpicForItem('${epic.id}', '${escapeHtml(epic.title || epic.name)}')`
// interpolates into a JS STRING LITERAL embedded in an HTML attribute, not
// element content and not a plain quoted attribute — a THIRD context this
// file's SITE 1 checks above do not exercise. escapeHtml leaves `'` and `\`
// untouched, so a title of `'); alert(1); //` needs no `"` at all to break
// out: it closes the string literal and the browser executes `alert(1)`
// as a live statement inside the onclick handler. Fixed: jsAttrEscape()
// for both epic.id and epic.title||epic.name.

const HOSTILE_JS_STRING_TITLE = "'); alert(1); //";
const HOSTILE_JS_STRING_TITLE_2 = "'); alert(2); //";

/** Walk a JS string literal from just after its opening quote; return the
 * index of the first UNESCAPED closing quote, or -1 if none is found.
 * `\` escapes the next character (matches real JS string-literal grammar
 * closely enough for the shapes these fixtures produce: a lone `\` or `\'`
 * from jsAttrEscape's own escaping). */
function walkJsStringArg(str, startIdx) {
    let i = startIdx;
    while (i < str.length) {
        if (str[i] === '\\') { i += 2; continue; }
        if (str[i] === "'") return i;
        i++;
    }
    return -1;
}

/** Two-argument JS-string-literal call, e.g. `fn('${a}', '${b}')` embedded in
 * an HTML attribute. `mustBreakOut` flips the expected outcome, matching the
 * NEGATIVE/POSITIVE control pairing used throughout this file: true asserts
 * the hostile payload DOES terminate the literal early (proves the
 * vulnerable shape is vulnerable); false asserts it does NOT (proves the
 * fixed shape is fixed). */
function checkJsStringCallIntegrity(label, html, openMarker, separator, tail, mustBreakOut) {
    const start = html.indexOf(openMarker);
    check(`${label}: found ${openMarker}`, start !== -1, true);
    if (start === -1) return;
    const firstClose = walkJsStringArg(html, start + openMarker.length);
    check(`${label}: first argument closes with an unescaped quote`, firstClose !== -1, true);
    if (firstClose === -1) return;
    const afterFirst = html.slice(firstClose, firstClose + separator.length);
    check(`${label}: first argument is followed by the expected separator "${separator}" (did not itself break out)`,
        afterFirst === separator, true);
    if (afterFirst !== separator) return;
    const secondArgStart = firstClose + separator.length;
    const secondClose = walkJsStringArg(html, secondArgStart);
    check(`${label}: second argument closes with an unescaped quote`, secondClose !== -1, true);
    if (secondClose === -1) return;
    const afterSecond = html.slice(secondClose, secondClose + tail.length);
    check(`${label}: hostile payload ${mustBreakOut ? 'DOES terminate' : 'does NOT terminate'} the JS string literal early (checked via the "${tail}" tail marker)`,
        afterSecond === tail, !mustBreakOut);
}

/** Single-argument JS-string-literal assignment, e.g.
 * `x.value = '${a}'` embedded in an HTML attribute (SITES 3/4). */
function checkJsStringAssignmentIntegrity(label, html, openMarker, tail, mustBreakOut) {
    const start = html.indexOf(openMarker);
    check(`${label}: found ${openMarker}`, start !== -1, true);
    if (start === -1) return;
    const closeIdx = walkJsStringArg(html, start + openMarker.length);
    check(`${label}: value string closes with an unescaped quote`, closeIdx !== -1, true);
    if (closeIdx === -1) return;
    const after = html.slice(closeIdx, closeIdx + tail.length);
    check(`${label}: hostile payload ${mustBreakOut ? 'DOES terminate' : 'does NOT terminate'} the JS string literal early (checked via the "${tail}" tail marker)`,
        after === tail, !mustBreakOut);
}

// --- NEGATIVE CONTROL: reproduce the OLD (escapeHtml, and for epic.id NO
// escaping at all) shape as a standalone fixture and prove the breakout. ---
function buildOldEpicOption(epicId, epicTitle) {
    return `<div class="epic-select-option" data-epic-id="${epicId}" onclick="selectEpicForItem('${epicId}', '${escapeHtml(epicTitle)}')"></div>`;
}
const oldEpicOption = buildOldEpicOption('EPIC-1', HOSTILE_JS_STRING_TITLE);
checkJsStringCallIntegrity('NEGATIVE CONTROL (pre-fix escapeHtml/no-escape epic selector)',
    oldEpicOption, "selectEpicForItem('", "', '", "')\"", /* mustBreakOut */ true);

// --- POSITIVE CONTROL: the same template, jsAttrEscape() for both args. ---
function buildFixedEpicOption(epicId, epicTitle) {
    return `<div class="epic-select-option" data-epic-id="${epicId}" onclick="selectEpicForItem('${jsAttrEscape(epicId)}', '${jsAttrEscape(epicTitle)}')"></div>`;
}
const fixedEpicOption = buildFixedEpicOption('EPIC-1', HOSTILE_JS_STRING_TITLE);
checkJsStringCallIntegrity('POSITIVE CONTROL (jsAttrEscape epic selector)',
    fixedEpicOption, "selectEpicForItem('", "', '", "')\"", /* mustBreakOut */ false);

// --- Source-level lock: pin the actual onclick statement to jsAttrEscape on
// BOTH arguments, so a future template refactor cannot silently regress the
// escaper choice. ---
const epicOnclickAssignment = source.match(
    /onclick="selectEpicForItem\('\$\{(\w+)\(epic\.id\)\}', '\$\{(\w+)\(epic\.title \|\| epic\.name\)\}'\)"/
);
check('source: selectEpicForItem onclick statement located in lcars.js (showEpicAssignModal\'s epic-option builder)',
    !!epicOnclickAssignment, true);
if (epicOnclickAssignment) {
    check('source: epic.id (first arg) uses jsAttrEscape — it lands in a JS string literal inside an HTML attribute',
        epicOnclickAssignment[1], 'jsAttrEscape');
    check('source: epic.title||epic.name (second arg) uses jsAttrEscape too, for the same JS-string-literal reason',
        epicOnclickAssignment[2], 'jsAttrEscape');
}

// --- LIVE integration: extract the REAL, currently-shipped
// showEpicAssignModal() and run it end-to-end against stub document/fetch.
// Run against pre-fix source this fails identically to the NEGATIVE CONTROL
// above; after the fix it passes identically to the POSITIVE CONTROL. ---
async function runSite2EpicSelectorTests() {
    let showEpicAssignModal;
    try {
        const slices = [
            extractFunction('escapeHtml_UNUSED_PLACEHOLDER_NEVER_MATCHES'),
        ];
    } catch (e) {
        // escapeHtml is DOM-backed in the real source (uses document.createElement),
        // so it is never extracted from lcars.js itself for these Node tests —
        // this placeholder attempt is expected to throw and is caught here only
        // to document that fact; the real extraction list follows below.
    }
    try {
        const slices = [
            extractFunction('escapeAttr'),
            extractFunction('jsAttrEscape'),
            extractAsyncFunction('showEpicAssignModal'),
        ].join('\n\n');

        // escapeHtml is DOM-backed in real lcars.js; faithful DOM-free stand-in,
        // matching the one used for SITE 1 above. pauseAutoRefresh/apiUrl/fetch
        // are stubbed minimally — just enough to observe what
        // showEpicAssignModal() actually RENDERS into the epic list, not to
        // simulate a browser. escapeAttr is now ALSO extracted (5th round,
        // XACA-1005-023): showEpicAssignModal's data-epic-id switched from
        // raw to escapeAttr(epic.id), a new dependency this factory did not
        // need before -- omitting it here would leave escapeAttr undefined
        // inside the `new Function` scope, throwing a ReferenceError that
        // showEpicAssignModal's own try/catch would swallow into an error
        // message, silently emptying the epic list this test inspects.
        const preamble =
            'function escapeHtml(t) { if (!t) return ""; return String(t)' +
            '.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }\n' +
            'function pauseAutoRefresh() {}\n' +
            'function apiUrl(p) { return p; }\n' +
            'var __fetchEpicsResponse = { epics: [], colors: {} };\n' +
            'function __setFetchEpicsResponse(data) { __fetchEpicsResponse = data; }\n' +
            'function fetch(url) {\n' +
            '  return Promise.resolve({ ok: true, json: function () { return Promise.resolve(__fetchEpicsResponse); } });\n' +
            '}\n' +
            // Pre-seed the modal shell as already existing, so the (unrelated,
            // static-markup-only) creation branch is skipped — the dynamic
            // epics list this test inspects is built identically either way.
            'var __listElStub = { innerHTML: "" };\n' +
            'var __modalStub = {\n' +
            '  dataset: {},\n' +
            '  style: {},\n' +
            '  querySelector: function (sel) {\n' +
            '    if (sel === ".assign-item-id" || sel === ".assign-item-title") return { textContent: "" };\n' +
            '    throw new Error("unstubbed modal.querySelector: " + sel);\n' +
            '  }\n' +
            '};\n' +
            'var __els = { "epic-assign-modal": __modalStub, "epic-select-list": __listElStub };\n' +
            'var document = {\n' +
            '  getElementById: function (id) { return __els[id] || null; },\n' +
            '  body: { insertAdjacentHTML: function () { throw new Error("unexpected insertAdjacentHTML — modal stub should already exist"); } }\n' +
            '};\n';

        // eslint-disable-next-line no-new-func
        const factory = new Function(
            preamble + slices +
            '\nreturn { showEpicAssignModal, __setFetchEpicsResponse, __getListHtml: function () { return __listElStub.innerHTML; } };'
        );
        showEpicAssignModal = factory();
    } catch (e) {
        fail(`SITE 2 live extraction/setup failed: ${e.message}`);
        return;
    }

    showEpicAssignModal.__setFetchEpicsResponse({
        epics: [{ id: 'EPIC-1', title: HOSTILE_JS_STRING_TITLE, itemCount: 2 }],
        colors: {},
    });
    await showEpicAssignModal.showEpicAssignModal('ITEM-1', 'Item Title', 'academy', null);
    const liveEpicHtml = showEpicAssignModal.__getListHtml();
    check('LIVE showEpicAssignModal(): epic list was rendered (non-empty)', liveEpicHtml.length > 0, true);
    checkJsStringCallIntegrity('LIVE showEpicAssignModal()',
        liveEpicHtml, "selectEpicForItem('", "', '", "')\"", /* mustBreakOut */ false);
}

// ===========================================================================
// SITES 3, 4 & 5 (folded-in scope expansion) — showMergeDialog(): two
// JS-STRING-LITERAL breakouts (SITES 3/4) and one QUOTED-ATTRIBUTE breakout
// (SITE 5) in the SAME function, on adjacent lines, requiring DIFFERENT
// escapers — jsAttrEscape for the onclick assignments, escapeAttr for the
// <input value="...">. A uniform swap across all four sites in this file
// would get this pair wrong in one direction or the other.
// ===========================================================================

const HOSTILE_ATTR_TITLE = 'Fix " onmouseover=alert(1) x="';

// --- NEGATIVE CONTROL fixtures: the OLD escapeHtml-everywhere shape. ---
function buildOldMergeMarkup(localTitle, externalTitle) {
    return `<input type="text" id="merge-title" value="${escapeHtml(localTitle)}" />` +
        `<button class="suggestion-btn" onclick="document.getElementById('merge-title').value = '${escapeHtml(localTitle)}'">Local</button>` +
        `<button class="suggestion-btn" onclick="document.getElementById('merge-title').value = '${escapeHtml(externalTitle)}'">Calendar</button>`;
}
const oldMergeMarkupJsString = buildOldMergeMarkup(HOSTILE_JS_STRING_TITLE, HOSTILE_JS_STRING_TITLE_2);
checkJsStringAssignmentIntegrity('NEGATIVE CONTROL (pre-fix escapeHtml merge "Local" button)',
    oldMergeMarkupJsString, "document.getElementById('merge-title').value = '", "'\"", /* mustBreakOut */ true);
checkJsStringAssignmentIntegrity('NEGATIVE CONTROL (pre-fix escapeHtml merge "Calendar" button)',
    oldMergeMarkupJsString, "document.getElementById('merge-title').value = '", "'\"", /* mustBreakOut */ true);

// --- POSITIVE CONTROL fixtures: jsAttrEscape for the onclick assignments,
// escapeAttr for the <input> value attribute. ---
function buildFixedMergeMarkup(localTitle, externalTitle) {
    return `<input type="text" id="merge-title" value="${escapeAttr(localTitle)}" />` +
        `<button class="suggestion-btn" onclick="document.getElementById('merge-title').value = '${jsAttrEscape(localTitle)}'">Local</button>` +
        `<button class="suggestion-btn" onclick="document.getElementById('merge-title').value = '${jsAttrEscape(externalTitle)}'">Calendar</button>`;
}
const fixedMergeMarkupJsString = buildFixedMergeMarkup(HOSTILE_JS_STRING_TITLE, HOSTILE_JS_STRING_TITLE_2);
checkJsStringAssignmentIntegrity('POSITIVE CONTROL (jsAttrEscape merge "Local" button)',
    fixedMergeMarkupJsString, "document.getElementById('merge-title').value = '", "'\"", /* mustBreakOut */ false);

/** SITE 5's structural check: reused shape from SITE 1's
 * assertCrTitleAttributeShape, retargeted at the merge-title <input>'s
 * value="..." attribute rather than a <button>'s title="...". */
function assertMergeTitleInputAttributeShape(label, inputTag, mustBreakOut) {
    if (!inputTag) {
        fail(`${label}: no <input id="merge-title"> tag to inspect`);
        return;
    }
    const valueMatch = inputTag.match(/value="([^"]*)"/);
    check(`${label}: a value attribute is present`, !!valueMatch, true);
    if (!valueMatch) return;
    const valueAttr = valueMatch[1];
    check(`${label}: value attribute text is ${mustBreakOut ? 'TRUNCATED at' : 'NOT truncated by'} the hostile raw quote`,
        valueAttr.indexOf('x=') !== -1, !mustBreakOut);
    const tagWithoutValue = inputTag.slice(0, valueMatch.index) + inputTag.slice(valueMatch.index + valueMatch[0].length);
    check(`${label}: onmouseover= ${mustBreakOut ? 'becomes' : 'does NOT become'} a live attribute on the <input> (checked OUTSIDE the value="..." attribute)`,
        /\bonmouseover\s*=/.test(tagWithoutValue), mustBreakOut);
    if (!mustBreakOut) {
        check(`${label}: the hostile quote is present as the &quot; entity, not raw`, /&quot;/.test(valueAttr), true);
        check(`${label}: value attribute contains no raw double quote`, valueAttr.indexOf('"') === -1, true);
    }
}

function extractInputTag(html, id) {
    const marker = `id="${id}"`;
    const markerIdx = html.indexOf(marker);
    if (markerIdx === -1) return null;
    const tagStart = html.lastIndexOf('<input', markerIdx);
    const tagEnd = html.indexOf('>', markerIdx);
    if (tagStart === -1 || tagEnd === -1) return null;
    return html.slice(tagStart, tagEnd + 1);
}

const oldMergeMarkupAttr = buildOldMergeMarkup(HOSTILE_ATTR_TITLE, 'benign external title');
assertMergeTitleInputAttributeShape('NEGATIVE CONTROL (pre-fix escapeHtml merge-title input)',
    extractInputTag(oldMergeMarkupAttr, 'merge-title'), /* mustBreakOut */ true);

const fixedMergeMarkupAttr = buildFixedMergeMarkup(HOSTILE_ATTR_TITLE, 'benign external title');
assertMergeTitleInputAttributeShape('POSITIVE CONTROL (escapeAttr merge-title input)',
    extractInputTag(fixedMergeMarkupAttr, 'merge-title'), /* mustBreakOut */ false);

// --- Source-level locks for all three sites. ---
const mergeInputAssignment = source.match(
    /<input type="text" id="merge-title" value="\$\{(\w+)\(localTitle\)\}" \/>/
);
check('source: merge-title <input value=...> statement located in lcars.js',
    !!mergeInputAssignment, true);
if (mergeInputAssignment) {
    check('source: merge-title <input> value uses escapeAttr — it is a plain quoted HTML attribute, not a JS string literal',
        mergeInputAssignment[1], 'escapeAttr');
}

const mergeLocalBtnAssignment = source.match(
    /document\.getElementById\('merge-title'\)\.value = '\$\{(\w+)\(localTitle\)\}'/
);
check('source: merge "Local" button onclick statement located in lcars.js', !!mergeLocalBtnAssignment, true);
if (mergeLocalBtnAssignment) {
    check('source: merge "Local" button uses jsAttrEscape — it lands in a JS string literal inside an HTML attribute',
        mergeLocalBtnAssignment[1], 'jsAttrEscape');
}

const mergeExternalBtnAssignment = source.match(
    /document\.getElementById\('merge-title'\)\.value = '\$\{(\w+)\(externalTitle\)\}'/
);
check('source: merge "Calendar" button onclick statement located in lcars.js', !!mergeExternalBtnAssignment, true);
if (mergeExternalBtnAssignment) {
    check('source: merge "Calendar" button uses jsAttrEscape too, for the same JS-string-literal reason',
        mergeExternalBtnAssignment[1], 'jsAttrEscape');
}

// --- LIVE integration: extract the REAL, currently-shipped showMergeDialog()
// and run it end-to-end against a stub conflict-item DOM. Run against
// pre-fix source this fails identically to the NEGATIVE CONTROLs above;
// after the fix it passes identically to the POSITIVE CONTROLs. ---
function runSite3to5MergeDialogTests() {
    let bound;
    try {
        const slices = [
            extractFunction('escapeAttr'),
            extractFunction('jsAttrEscape'),
            extractFunction('showMergeDialog'),
        ].join('\n\n');

        const preamble =
            'function escapeHtml(t) { if (!t) return ""; return String(t)' +
            '.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }\n' +
            'var __lastAppended = null;\n' +
            'var __conflictItemStub = null;\n' +
            'function __setConflictItemStub(values) {\n' +
            '  __conflictItemStub = {\n' +
            '    querySelector: function (sel) {\n' +
            '      if (sel === ".local-version .field-value:nth-of-type(1)") return { textContent: values.localTitle };\n' +
            '      if (sel === ".local-version .field-value:nth-of-type(2)") return { textContent: values.localDueDate };\n' +
            '      if (sel === ".external-version .field-value:nth-of-type(1)") return { textContent: values.externalTitle };\n' +
            '      if (sel === ".external-version .field-value:nth-of-type(2)") return { textContent: values.externalDueDate };\n' +
            '      if (sel === ".conflict-actions") return { appendChild: function (el) { __lastAppended = el; } };\n' +
            '      throw new Error("unstubbed conflictItem.querySelector: " + sel);\n' +
            '    }\n' +
            '  };\n' +
            '}\n' +
            'var document = {\n' +
            '  querySelector: function () { return __conflictItemStub; },\n' +
            '  createElement: function () { return { className: "", innerHTML: "" }; }\n' +
            '};\n';

        // eslint-disable-next-line no-new-func
        const factory = new Function(
            preamble + slices +
            '\nreturn { showMergeDialog, __setConflictItemStub, __getLastAppended: function () { return __lastAppended; } };'
        );
        bound = factory();
    } catch (e) {
        fail(`SITES 3-5 live extraction/setup failed: ${e.message}`);
        return;
    }

    // Pass 1: JS-string payloads, to exercise SITES 3 & 4.
    bound.__setConflictItemStub({
        localTitle: HOSTILE_JS_STRING_TITLE,
        localDueDate: 'None',
        externalTitle: HOSTILE_JS_STRING_TITLE_2,
        externalDueDate: 'None',
    });
    bound.showMergeDialog('ITEM-1', 0);
    const liveJsStringHtml = bound.__getLastAppended() && bound.__getLastAppended().innerHTML;
    check('LIVE showMergeDialog(): merge dialog was appended (non-empty innerHTML)',
        !!liveJsStringHtml && liveJsStringHtml.length > 0, true);
    if (liveJsStringHtml) {
        checkJsStringAssignmentIntegrity('LIVE showMergeDialog() "Local" button',
            liveJsStringHtml, "document.getElementById('merge-title').value = '", "'\"", /* mustBreakOut */ false);
        checkJsStringAssignmentIntegrity('LIVE showMergeDialog() "Calendar" button',
            liveJsStringHtml, "document.getElementById('merge-title').value = '", "'\"", /* mustBreakOut */ false);
    }

    // Pass 2: raw-double-quote payload, to exercise SITE 5's <input value=...>.
    bound.__setConflictItemStub({
        localTitle: HOSTILE_ATTR_TITLE,
        localDueDate: 'None',
        externalTitle: 'benign external title',
        externalDueDate: 'None',
    });
    bound.showMergeDialog('ITEM-2', 0);
    const liveAttrHtml = bound.__getLastAppended() && bound.__getLastAppended().innerHTML;
    check('LIVE showMergeDialog() (2nd payload): merge dialog was appended (non-empty innerHTML)',
        !!liveAttrHtml && liveAttrHtml.length > 0, true);
    if (liveAttrHtml) {
        assertMergeTitleInputAttributeShape('LIVE showMergeDialog() merge-title input',
            extractInputTag(liveAttrHtml, 'merge-title'), /* mustBreakOut */ false);
    }
}


// ===========================================================================
// SITES 6 & 7 (2nd folded-in scope expansion) — calendar day items,
// renderDayItems(): two QUOTED-ATTRIBUTE breakouts, no escaper at all (not
// merely the wrong one), plus one independently-judged unsafe class-name
// interpolation (priorityClass) found while evaluating the same two lines.
// ===========================================================================
//
// SITE 6 (epic branch, ~8726): titleText (built from item.title two lines
// above) was interpolated RAW into title="Epic: ${titleText} ...". Fixed:
// escapeAttr(titleText) at the interpolation site -- verified titleText has
// exactly one consumer in this branch before choosing to escape there rather
// than at its `const titleText = ...` construction.
//
// SITE 7 (kanban-item branch, ~8765): item.title was interpolated RAW into
// title="${item.id}: ${item.title} ...". Fixed: escapeAttr(item.title).
//
// priorityClass (SITE 7, same line, class="calendar-item priority-${...}"):
// independently evaluated per the "do not reflexively escape" note and judged
// GENUINELY UNSAFE, unlike urgencyClass/item.id in the same lines --
// item.priority reaches this render via server.py's handle_update_item, which
// applies `updates.items()` as a fully generic field setter with NO enum
// validation on `priority` for backlog items (the TODO_PRIORITY_ORDER enum
// check gates a DIFFERENT resource). Fixed: escapeAttr(priorityClass).
//
// urgencyClass (both sites) and item.id (both sites) were left unescaped --
// see the reasoning recorded as comments at each site in lcars.js itself
// (urgencyClass: fixed literal set from getUrgencyClass(), no external input;
// item.id: constrained-charset generator on the normal creation path, with an
// out-of-scope mass-assignment caveat reported to the coordinator, not fixed
// here). Not re-litigated in this test file; the LIVE checks below assert
// urgencyClass/item.id are NOT touched (still render verbatim), which is the
// test-level expression of "left alone, deliberately".

function extractDivTag(html, marker) {
    const markerIdx = html.indexOf(marker);
    if (markerIdx === -1) return null;
    const tagStart = html.lastIndexOf('<div', markerIdx);
    const tagEnd = html.indexOf('>', markerIdx);
    if (tagStart === -1 || tagEnd === -1) return null;
    return html.slice(tagStart, tagEnd + 1);
}

/** SITE 7's class="..." structural check -- same shape as
 * assertCrTitleAttributeShape/assertMergeTitleInputAttributeShape above,
 * retargeted at the class attribute and a distinct tail marker (`y="`) so a
 * failure message cannot be confused with the title-attribute check running
 * on the SAME tag in the SAME test. */
function assertPriorityClassAttributeShape(label, tag, mustBreakOut) {
    if (!tag) {
        fail(`${label}: no tag to inspect`);
        return;
    }
    const classMatch = tag.match(/class="([^"]*)"/);
    check(`${label}: a class attribute is present`, !!classMatch, true);
    if (!classMatch) return;
    const classAttr = classMatch[1];
    check(`${label}: class attribute text is ${mustBreakOut ? 'TRUNCATED at' : 'NOT truncated by'} the hostile raw quote`,
        classAttr.indexOf('y=') !== -1, !mustBreakOut);
    const tagWithoutClass = tag.slice(0, classMatch.index) + tag.slice(classMatch.index + classMatch[0].length);
    // Uses 'onclick=' rather than 'onmouseover=' (SITE 1/6/7's title-attribute
    // marker) deliberately: SITE 7's tag carries BOTH a class="..." and a
    // title="..." attribute, and the title-attribute payload's inert
    // "onmouseover=" text would otherwise still be present, escaped, inside
    // THIS check's tag string too -- a false positive from marker collision,
    // not from an actual breakout. Distinct markers per attribute keep each
    // check's positive control meaningful when both hostile payloads are
    // exercised against the same tag.
    check(`${label}: onclick= ${mustBreakOut ? 'becomes' : 'does NOT become'} a live attribute on the tag (checked OUTSIDE the class="..." attribute)`,
        /\bonclick\s*=/.test(tagWithoutClass), mustBreakOut);
    if (!mustBreakOut) {
        check(`${label}: the hostile quote is present as the &quot; entity, not raw`, /&quot;/.test(classAttr), true);
        check(`${label}: class attribute contains no raw double quote`, classAttr.indexOf('"') === -1, true);
    }
}

const HOSTILE_PRIORITY_CLASS = 'x" onclick=alert(2) y="';

// --- NEGATIVE CONTROL fixtures: the OLD no-escaper-at-all shape. ---
function buildOldEpicDayItem(id, title, urgencyClass) {
    const titleText = title; // progress omitted -> ternary falls to item.title
    return `<div class="calendar-item epic-item ${urgencyClass}" data-epic-id="${id}" title="Epic: ${titleText} (click to navigate)"></div>`;
}
function buildOldKanbanDayItem(id, title, priorityClassRaw, urgencyClass) {
    return `<div class="calendar-item priority-${priorityClassRaw} ${urgencyClass}" data-item-id="${id}" title="${id}: ${title} (click to navigate)"></div>`;
}
const oldEpicDayItem = buildOldEpicDayItem('EPIC-1', HOSTILE_ATTR_TITLE, 'urgency-future');
assertCrTitleAttributeShape('NEGATIVE CONTROL (pre-fix no-escaper epic day item, SITE 6)',
    oldEpicDayItem, /* mustBreakOut */ true);
const oldKanbanDayItem = buildOldKanbanDayItem('ITEM-1', HOSTILE_ATTR_TITLE, HOSTILE_PRIORITY_CLASS, 'urgency-future');
assertCrTitleAttributeShape('NEGATIVE CONTROL (pre-fix no-escaper kanban day item title, SITE 7)',
    oldKanbanDayItem, /* mustBreakOut */ true);
assertPriorityClassAttributeShape('NEGATIVE CONTROL (pre-fix no-escaper kanban day item priorityClass, SITE 7)',
    oldKanbanDayItem, /* mustBreakOut */ true);

// --- POSITIVE CONTROL fixtures: escapeAttr() at each site. ---
function buildFixedEpicDayItem(id, title, urgencyClass) {
    const titleText = title;
    return `<div class="calendar-item epic-item ${urgencyClass}" data-epic-id="${id}" title="Epic: ${escapeAttr(titleText)} (click to navigate)"></div>`;
}
function buildFixedKanbanDayItem(id, title, priorityClassRaw, urgencyClass) {
    return `<div class="calendar-item priority-${escapeAttr(priorityClassRaw)} ${urgencyClass}" data-item-id="${id}" title="${id}: ${escapeAttr(title)} (click to navigate)"></div>`;
}
const fixedEpicDayItem = buildFixedEpicDayItem('EPIC-1', HOSTILE_ATTR_TITLE, 'urgency-future');
assertCrTitleAttributeShape('POSITIVE CONTROL (escapeAttr epic day item, SITE 6)',
    fixedEpicDayItem, /* mustBreakOut */ false);
const fixedKanbanDayItem = buildFixedKanbanDayItem('ITEM-1', HOSTILE_ATTR_TITLE, HOSTILE_PRIORITY_CLASS, 'urgency-future');
assertCrTitleAttributeShape('POSITIVE CONTROL (escapeAttr kanban day item title, SITE 7)',
    fixedKanbanDayItem, /* mustBreakOut */ false);
assertPriorityClassAttributeShape('POSITIVE CONTROL (escapeAttr kanban day item priorityClass, SITE 7)',
    fixedKanbanDayItem, /* mustBreakOut */ false);

// --- Source-level locks for all three interpolations. ---
const epicTitleTextAssignment = source.match(
    /title="Epic: \$\{(\w+)\(titleText\)\} \(click to navigate\)"/
);
check('source: epic day-item title="..." statement located in lcars.js (SITE 6)',
    !!epicTitleTextAssignment, true);
if (epicTitleTextAssignment) {
    check('source: SITE 6 titleText uses escapeAttr — a plain quoted HTML attribute',
        epicTitleTextAssignment[1], 'escapeAttr');
}

const kanbanTitleAssignment = source.match(
    /title="\$\{item\.id\}: \$\{(\w+)\(item\.title\)\} \(click to navigate\)"/
);
check('source: kanban day-item title="..." statement located in lcars.js (SITE 7)',
    !!kanbanTitleAssignment, true);
if (kanbanTitleAssignment) {
    check('source: SITE 7 item.title uses escapeAttr — a plain quoted HTML attribute',
        kanbanTitleAssignment[1], 'escapeAttr');
}

const priorityClassAssignment = source.match(
    /class="calendar-item priority-\$\{(\w+)\(priorityClass\)\} \$\{urgencyClass\}"/
);
check('source: kanban day-item class="..." statement located in lcars.js (SITE 7 priorityClass)',
    !!priorityClassAssignment, true);
if (priorityClassAssignment) {
    check('source: SITE 7 priorityClass uses escapeAttr — independently judged unsafe (unvalidated item.priority), same quoted-attribute reasoning',
        priorityClassAssignment[1], 'escapeAttr');
}

// urgencyClass/item.id anti-regression: confirm they are NOT wrapped in any
// escaper call at either site, i.e. the "leave alone, deliberately" judgment
// is what actually shipped, not silently over-escaped defensive noise.
check('source: SITE 6/7 urgencyClass is interpolated bare (${urgencyClass}), not escaper-wrapped, matching the "safe, fixed literal set" judgment',
    (source.match(/\$\{urgencyClass\}/g) || []).length >= 2, true);
check('source: SITE 6/7 data-epic-id/data-item-id use bare ${item.id}, not escaper-wrapped, matching the "safe on the normal creation path" judgment',
    /data-epic-id="\$\{item\.id\}"/.test(source) && /data-item-id="\$\{item\.id\}"/.test(source), true);

// --- LIVE integration: extract the REAL, currently-shipped renderDayItems()
// and run it end-to-end against a stub calendarState. renderDayItems() has
// no DOM/fetch dependency at all (pure string building over module state),
// so no stub document/fetch is needed -- only calendarState. ---

// ===========================================================================
// FINDINGS A, B & C (3rd folded-in scope expansion) — three more raw
// interpolations found while tracing SITES 6/7, all inside the SAME
// renderDayItems() function, folded into this ticket because SITE 7 already
// escapes item.title on one line while these leave the SAME field (or a
// sibling field of the identical provenance) raw a few lines away.
//
// FINDING A (HIGHEST SEVERITY, LIVE PATH) — kanban-item branch's row2:
// `<div class="calendar-item-row2">${item.title}</div>` interpolated
// item.title RAW as ELEMENT CONTENT, no escaper at all. Unlike every other
// site in this file, this is not an attribute-context breakout -- a title
// containing a real <img>/<script> tag renders as a LIVE ELEMENT, no
// attribute boundary needs breaking. Fixed: escapeHtml(item.title) --
// escapeAttr() would also be safe here (see SITE 1's superset argument), but
// escapeHtml() is the conventional escaper for plain element content and
// matches the rest of the file's convention for this shape.
//
// FINDING B (FORWARD-SAFETY, NOT A LIVE HOLE) — external-calendar-event
// branch: item.title/item.source interpolated RAW into two title="..."
// attributes. VERIFIED DEAD CODE, not merely unlikely: lcars.js:7769 fetches
// `/api/calendar/external?start=...&end=...`, and grepping the entire repo
// for that path returns exactly one hit -- that fetch call itself. No
// handler for it exists anywhere in lcars-ui/server.py (the real external-
// events endpoint, used elsewhere, is the DIFFERENT path `/api/calendar/
// events`). So `calendarState.externalEvents` is always `[]` in the shipped
// app -- the request 404s forever and this branch's `if (item.isExternal)`
// never becomes true today. Fixed anyway (escapeAttr() on both
// interpolations, same as SITES 3/4's externalTitle/SITE 1's crTitle
// reasoning) because a one-line fix on a currently-unreachable branch is far
// cheaper now than remembering to add it the day someone wires up that
// route. Framed here as HARDENING, not as closing a reachable hole -- the
// LIVE test pass below exercises this branch directly (calling
// renderDayItems() with calendarState.externalEvents populated by hand,
// bypassing the missing fetch entirely), which proves the STRING-BUILDING
// code is now safe independent of whether the route is ever wired up; it
// does not and cannot prove the route is reachable, because it isn't.
// Whether that 404 is itself worth fixing is explicitly someone else's
// scope -- not touched, not filed, per instruction.
//
// FINDING C (LIVE PATH) — kanban-item branch's epicBadge:
// `title="Part of epic: ${getEpicTitleById(item.epicId) || item.epicName || item.epicId}"`
// interpolated the whole fallback chain RAW. The FIRST branch,
// getEpicTitleById(), resolves an epic TITLE -- user-supplied free text,
// same provenance as SITE 2's epic.title (server.py's epic-creation handler
// assigns the POST body's `name` straight through, no sanitization). Fixed:
// escapeAttr() wraps the whole ternary chain at this one interpolation site.

const HOSTILE_ELEMENT_CONTENT_TITLE = '<img src=x onerror=alert(3)>';

/** Generic opening-tag extractor: locate the nearest `<TAGPREFIX ...>`
 * whose text contains `marker`, walking backward from `marker` to the tag's
 * own start and forward to its closing '>'. Distinct from extractDivTag
 * above only in that the tag name is parameterised, needed because FINDING
 * B's two hostile title="..." attributes sit on DIFFERENT tags (an outer
 * <div> and an inner <span>) that must not be confused with each other. */
function extractOpeningTag(html, tagPrefix, marker) {
    const markerIdx = html.indexOf(marker);
    if (markerIdx === -1) return null;
    const tagStart = html.lastIndexOf(tagPrefix, markerIdx);
    const tagEnd = html.indexOf('>', markerIdx);
    if (tagStart === -1 || tagEnd === -1) return null;
    return html.slice(tagStart, tagEnd + 1);
}

/** FINDING A's assertion shape is NECESSARILY DIFFERENT from every
 * attribute-shape check above: there is no quote to truncate and no second
 * attribute to inject. The property that matters here is "a raw '<' cannot
 * introduce an element" -- checked by searching for the literal, UNESCAPED
 * substring '<img' in the element's text content. If escapeHtml() ran, '<'
 * becomes '&lt;' and that substring cannot occur; if it did not run, the
 * literal tag text is what a browser would parse as a real element. */
function assertElementContentNotInjectable(label, elementContent, mustBreakOut) {
    if (elementContent === null) {
        fail(`${label}: element content not found`);
        return;
    }
    check(`${label}: hostile <img> ${mustBreakOut ? 'DOES' : 'does NOT'} introduce a raw element (checked for a literal, unescaped '<img' substring)`,
        elementContent.indexOf('<img') !== -1, mustBreakOut);
    if (!mustBreakOut) {
        check(`${label}: the hostile '<' survives as the &lt; entity, not raw`,
            elementContent.indexOf('&lt;img') !== -1, true);
        check(`${label}: the hostile onerror= text is present but INERT (no raw '<' precedes it, so it cannot attach to a real element)`,
            elementContent.indexOf('onerror=') !== -1, true);
    }
}

function extractElementContent(html, openTagMarker, closeTag) {
    const start = html.indexOf(openTagMarker);
    if (start === -1) return null;
    const contentStart = start + openTagMarker.length;
    const end = html.indexOf(closeTag, contentStart);
    if (end === -1) return null;
    return html.slice(contentStart, end);
}

// --- FINDING A: NEGATIVE/POSITIVE CONTROL fixtures ---
function buildOldRow2(title) {
    return `<div class="calendar-item-row2">${title}</div>`;
}
function buildFixedRow2(title) {
    return `<div class="calendar-item-row2">${escapeHtml(title)}</div>`;
}
assertElementContentNotInjectable('NEGATIVE CONTROL (pre-fix no-escaper row2, FINDING A)',
    extractElementContent(buildOldRow2(HOSTILE_ELEMENT_CONTENT_TITLE), '<div class="calendar-item-row2">', '</div>'),
    /* mustBreakOut */ true);
assertElementContentNotInjectable('POSITIVE CONTROL (escapeHtml row2, FINDING A)',
    extractElementContent(buildFixedRow2(HOSTILE_ELEMENT_CONTENT_TITLE), '<div class="calendar-item-row2">', '</div>'),
    /* mustBreakOut */ false);

// --- FINDING B: NEGATIVE/POSITIVE CONTROL fixtures ---
function buildOldExternalEventMarkup(title, source) {
    const sourceLabel = source ? ` (${source})` : '';
    return `<div class="calendar-item external-event" title="${title}${sourceLabel}">` +
        `<span class="event-sync-badge" title="Synced from ${source || 'external calendar'}">↻</span></div>`;
}
function buildFixedExternalEventMarkup(title, source) {
    const sourceLabel = source ? ` (${source})` : '';
    return `<div class="calendar-item external-event" title="${escapeAttr(title)}${escapeAttr(sourceLabel)}">` +
        `<span class="event-sync-badge" title="Synced from ${escapeAttr(source || 'external calendar')}">↻</span></div>`;
}
const oldExternalEventMarkup = buildOldExternalEventMarkup(HOSTILE_ATTR_TITLE, null);
assertCrTitleAttributeShape('NEGATIVE CONTROL (pre-fix no-escaper external-event div title, FINDING B)',
    extractOpeningTag(oldExternalEventMarkup, '<div', 'class="calendar-item external-event"'),
    /* mustBreakOut */ true);
const fixedExternalEventMarkup = buildFixedExternalEventMarkup(HOSTILE_ATTR_TITLE, null);
assertCrTitleAttributeShape('POSITIVE CONTROL (escapeAttr external-event div title, FINDING B)',
    extractOpeningTag(fixedExternalEventMarkup, '<div', 'class="calendar-item external-event"'),
    /* mustBreakOut */ false);
const oldSyncBadgeMarkup = buildOldExternalEventMarkup('benign title', HOSTILE_ATTR_TITLE);
assertCrTitleAttributeShape('NEGATIVE CONTROL (pre-fix no-escaper sync-badge title, FINDING B)',
    extractOpeningTag(oldSyncBadgeMarkup, '<span', 'class="event-sync-badge"'),
    /* mustBreakOut */ true);
const fixedSyncBadgeMarkup = buildFixedExternalEventMarkup('benign title', HOSTILE_ATTR_TITLE);
assertCrTitleAttributeShape('POSITIVE CONTROL (escapeAttr sync-badge title, FINDING B)',
    extractOpeningTag(fixedSyncBadgeMarkup, '<span', 'class="event-sync-badge"'),
    /* mustBreakOut */ false);

// --- FINDING C: NEGATIVE/POSITIVE CONTROL fixtures ---
function buildOldEpicBadge(resolvedTitle) {
    return `<span class="epic-badge" title="Part of epic: ${resolvedTitle}">E</span>`;
}
function buildFixedEpicBadge(resolvedTitle) {
    return `<span class="epic-badge" title="Part of epic: ${escapeAttr(resolvedTitle)}">E</span>`;
}
assertCrTitleAttributeShape('NEGATIVE CONTROL (pre-fix no-escaper epicBadge, FINDING C)',
    buildOldEpicBadge(HOSTILE_ATTR_TITLE), /* mustBreakOut */ true);
assertCrTitleAttributeShape('POSITIVE CONTROL (escapeAttr epicBadge, FINDING C)',
    buildFixedEpicBadge(HOSTILE_ATTR_TITLE), /* mustBreakOut */ false);

// --- Source-level locks for all three. ---
const row2Assignment = source.match(/<div class="calendar-item-row2">\$\{(\w+)\(String\(item\.title \?\? ''\)\)\}<\/div>/);
check('source: row2 statement located in lcars.js (FINDING A)', !!row2Assignment, true);
if (row2Assignment) {
    check('source: FINDING A row2 uses escapeHtml — plain element content, not an attribute',
        row2Assignment[1], 'escapeHtml');
}

const extDivAssignment = source.match(
    /<div class="calendar-item external-event" title="\$\{(\w+)\(item\.title\)\}\$\{(\w+)\(sourceLabel\)\}">/
);
check('source: external-event div title="..." statement located in lcars.js (FINDING B)', !!extDivAssignment, true);
if (extDivAssignment) {
    check('source: FINDING B external-event div title item.title uses escapeAttr',
        extDivAssignment[1], 'escapeAttr');
    check('source: FINDING B external-event div title sourceLabel uses escapeAttr',
        extDivAssignment[2], 'escapeAttr');
}

const syncBadgeAssignment = source.match(
    /title="Synced from \$\{(\w+)\(item\.source \|\| 'external calendar'\)\}"/
);
check('source: sync-badge title="..." statement located in lcars.js (FINDING B)', !!syncBadgeAssignment, true);
if (syncBadgeAssignment) {
    check('source: FINDING B sync-badge title uses escapeAttr',
        syncBadgeAssignment[1], 'escapeAttr');
}

const epicBadgeAssignment = source.match(
    /title="Part of epic: \$\{(\w+)\(getEpicTitleById\(item\.epicId\) \|\| item\.epicName \|\| item\.epicId\)\}"/
);
check('source: epicBadge title="..." statement located in lcars.js (FINDING C)', !!epicBadgeAssignment, true);
if (epicBadgeAssignment) {
    check('source: FINDING C epicBadge uses escapeAttr',
        epicBadgeAssignment[1], 'escapeAttr');
}

function runSite6And7CalendarDayTests() {
    // Extended for the 3rd folded-in scope expansion (FINDINGS A/B/C), all
    // three inside this same renderDayItems() function: escapeHtml (element
    // content, FINDING A), getEpicTitleById + a boardData stub (FINDING C's
    // epic-title lookup), and calendarState.showExternalEvents/externalEvents
    // toggled on in later passes below to exercise FINDING B's branch (kept
    // OFF for the earlier SITE 6/7 passes, which do not need it).
    let renderDayItems;
    try {
        const slices = [
            extractFunction('escapeAttr'),
            extractFunction('parseLocalDate'),
            extractFunction('getDueDateStatus'),
            extractFunction('getUrgencyClass'),
            extractFunction('truncateTitle'),
            extractFunction('getEpicTitleById'),
            extractFunction('renderDayItems'),
        ].join('\n\n');

        // escapeHtml is DOM-backed in real lcars.js; faithful DOM-free
        // stand-in, matching every other factory in this file. calendarState
        // and boardData are module-level state in real lcars.js;
        // renderDayItems reads calendarState.epicFilter/cachedEpics/
        // cachedItems/showExternalEvents/externalEvents, and
        // getEpicTitleById reads boardData.epics. epicFilter: 'all' so
        // nothing is filtered out.
        const preamble = 'function escapeHtml(t) { if (!t) return ""; return String(t)' +
            '.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }\n' +
            'var calendarState = { epicFilter: "all", cachedEpics: [], cachedItems: [], showExternalEvents: false, externalEvents: [] };\n' +
            'var boardData = { epics: [] };\n';

        // eslint-disable-next-line no-new-func
        const factory = new Function(
            preamble + slices +
            '\nreturn { renderDayItems, __setCalendarState: function (s) { Object.assign(calendarState, s); }, __setBoardData: function (s) { Object.assign(boardData, s); } };'
        );
        renderDayItems = factory();
    } catch (e) {
        fail(`SITES 6-7 live extraction/setup failed: ${e.message}`);
        return;
    }

    // Pass 1: hostile epic (SITE 6).
    renderDayItems.__setCalendarState({
        cachedEpics: [{
            id: 'EPIC-1', dueDate: '2026-01-01', title: HOSTILE_ATTR_TITLE,
            priority: 'medium', status: 'active', itemCount: 0, completedCount: 0,
        }],
        cachedItems: [],
    });
    const liveEpicHtml = renderDayItems.renderDayItems(new Date('2026-01-01T00:00:00'));
    check('LIVE renderDayItems(): epic day item was rendered (non-empty)', liveEpicHtml.length > 0, true);
    const liveEpicTag = extractDivTag(liveEpicHtml, 'data-epic-id="EPIC-1"');
    assertCrTitleAttributeShape('LIVE renderDayItems() epic day item (SITE 6)', liveEpicTag, /* mustBreakOut */ false);
    if (liveEpicTag) {
        check('LIVE renderDayItems(): SITE 6 urgencyClass still renders bare (left alone, deliberately)',
            /class="calendar-item epic-item urgency-\w+"/.test(liveEpicTag), true);
        check('LIVE renderDayItems(): SITE 6 item.id still renders bare in data-epic-id (left alone, deliberately)',
            liveEpicTag.indexOf('data-epic-id="EPIC-1"') !== -1, true);
    }

    // Pass 2: hostile kanban item (SITE 7 + priorityClass).
    renderDayItems.__setCalendarState({
        cachedEpics: [],
        cachedItems: [{
            id: 'ITEM-1', dueDate: '2026-01-01', title: HOSTILE_ATTR_TITLE,
            priority: HOSTILE_PRIORITY_CLASS, status: 'todo',
            epicId: null, epicName: null, subitemCount: 0,
        }],
    });
    const liveKanbanHtml = renderDayItems.renderDayItems(new Date('2026-01-01T00:00:00'));
    check('LIVE renderDayItems(): kanban day item was rendered (non-empty)', liveKanbanHtml.length > 0, true);
    const liveKanbanTag = extractDivTag(liveKanbanHtml, 'data-item-id="ITEM-1"');
    assertCrTitleAttributeShape('LIVE renderDayItems() kanban day item title (SITE 7)', liveKanbanTag, /* mustBreakOut */ false);
    assertPriorityClassAttributeShape('LIVE renderDayItems() kanban day item priorityClass (SITE 7)', liveKanbanTag, /* mustBreakOut */ false);
    if (liveKanbanTag) {
        check('LIVE renderDayItems(): SITE 7 urgencyClass still renders bare (left alone, deliberately)',
            / urgency-\w+"/.test(liveKanbanTag), true);
        check('LIVE renderDayItems(): SITE 7 item.id still renders bare in data-item-id (left alone, deliberately)',
            liveKanbanTag.indexOf('data-item-id="ITEM-1"') !== -1, true);
    }

    // Pass 3: FINDING A -- row2 element content, same hostile kanban item
    // (ITEM-1) from Pass 2, reusing liveKanbanHtml already rendered above.
    check('LIVE renderDayItems(): SITE 7 tag still located (precondition for FINDING A)', !!liveKanbanTag, true);
    const liveRow2Content = extractElementContent(liveKanbanHtml, '<div class="calendar-item-row2">', '</div>');
    // The row2 fixture uses HOSTILE_ELEMENT_CONTENT_TITLE, not
    // HOSTILE_ATTR_TITLE -- re-render with that payload specifically, since
    // Pass 2's item.title (HOSTILE_ATTR_TITLE) does not contain an <img> tag
    // and would not exercise this assertion meaningfully.
    renderDayItems.__setCalendarState({
        cachedEpics: [],
        cachedItems: [{
            id: 'ITEM-2', dueDate: '2026-01-01', title: HOSTILE_ELEMENT_CONTENT_TITLE,
            priority: 'medium', status: 'todo', epicId: null, epicName: null, subitemCount: 0,
        }],
    });
    const liveRow2Html = renderDayItems.renderDayItems(new Date('2026-01-01T00:00:00'));
    check('LIVE renderDayItems(): FINDING A day item was rendered (non-empty)', liveRow2Html.length > 0, true);
    assertElementContentNotInjectable('LIVE renderDayItems() row2 (FINDING A)',
        extractElementContent(liveRow2Html, '<div class="calendar-item-row2">', '</div>'),
        /* mustBreakOut */ false);
    // liveRow2Content (Pass 2's payload) unused beyond this existence check --
    // kept only to document why a second, dedicated payload/pass was needed.
    check('LIVE renderDayItems(): Pass 2 row2 content (non-hostile-<img> payload) exists, for contrast with Pass 3',
        liveRow2Content !== null, true);

    // Pass 4: FINDING B -- external-calendar-event branch. Bypasses the
    // (currently 404ing, per the coordinator's verified finding) fetch
    // entirely by populating calendarState.externalEvents directly, which is
    // exactly what a real, working route would eventually do. Proves the
    // STRING-BUILDING code is safe independent of whether that route exists.
    renderDayItems.__setCalendarState({
        cachedEpics: [], cachedItems: [],
        showExternalEvents: true,
        externalEvents: [{
            start: '2026-01-01T09:00:00', title: HOSTILE_ATTR_TITLE, source: null,
        }],
    });
    const liveExternalTitleHtml = renderDayItems.renderDayItems(new Date('2026-01-01T00:00:00'));
    check('LIVE renderDayItems(): FINDING B external-event day item was rendered (non-empty)', liveExternalTitleHtml.length > 0, true);
    assertCrTitleAttributeShape('LIVE renderDayItems() external-event div title (FINDING B)',
        extractOpeningTag(liveExternalTitleHtml, '<div', 'class="calendar-item external-event"'),
        /* mustBreakOut */ false);

    renderDayItems.__setCalendarState({
        cachedEpics: [], cachedItems: [],
        showExternalEvents: true,
        externalEvents: [{
            start: '2026-01-01T09:00:00', title: 'benign title', source: HOSTILE_ATTR_TITLE,
        }],
    });
    const liveExternalSourceHtml = renderDayItems.renderDayItems(new Date('2026-01-01T00:00:00'));
    check('LIVE renderDayItems(): FINDING B external-event sync-badge day item was rendered (non-empty)', liveExternalSourceHtml.length > 0, true);
    assertCrTitleAttributeShape('LIVE renderDayItems() external-event sync-badge title (FINDING B)',
        extractOpeningTag(liveExternalSourceHtml, '<span', 'class="event-sync-badge"'),
        /* mustBreakOut */ false);

    // Pass 5: FINDING C -- epicBadge, exercised on a kanban item WITH an
    // epicId, resolving through getEpicTitleById() against a stub boardData.
    renderDayItems.__setBoardData({
        epics: [{ id: 'EPIC-42', title: HOSTILE_ATTR_TITLE, name: 'fallback name' }],
    });
    renderDayItems.__setCalendarState({
        cachedEpics: [],
        cachedItems: [{
            id: 'ITEM-3', dueDate: '2026-01-01', title: 'benign kanban title',
            priority: 'medium', status: 'todo', epicId: 'EPIC-42', epicName: 'fallback name', subitemCount: 0,
        }],
    });
    const liveEpicBadgeHtml = renderDayItems.renderDayItems(new Date('2026-01-01T00:00:00'));
    check('LIVE renderDayItems(): FINDING C epicBadge day item was rendered (non-empty)', liveEpicBadgeHtml.length > 0, true);
    assertCrTitleAttributeShape('LIVE renderDayItems() epicBadge (FINDING C)',
        extractOpeningTag(liveEpicBadgeHtml, '<span', 'class="epic-badge"'),
        /* mustBreakOut */ false);

    // Pass 6 (5th round, BLOCKING, reviewer-verified) -- epic branch's
    // `${truncateTitle(displayTitle, 20)}` badge text, exercised with an
    // <img>-tag payload. displayTitle = item.shortTitle || item.title, and
    // this test's epic push (like the real one in renderDayItems() itself)
    // sets only `title`, so displayTitle resolves to item.title here.
    renderDayItems.__setBoardData({ epics: [] });
    renderDayItems.__setCalendarState({
        cachedEpics: [{
            id: 'EPIC-99', dueDate: '2026-01-01', title: HOSTILE_ELEMENT_CONTENT_TITLE,
            priority: 'medium', status: 'active', itemCount: 0, completedCount: 0,
        }],
        cachedItems: [],
    });
    const liveEpicBadgeTextHtml = renderDayItems.renderDayItems(new Date('2026-01-01T00:00:00'));
    check('LIVE renderDayItems(): Pass 6 epic badge-text day item was rendered (non-empty)', liveEpicBadgeTextHtml.length > 0, true);
    const epicBadgeTextMarker = '<span class="epic-badge">E</span> ';
    const epicBadgeTextStart = liveEpicBadgeTextHtml.indexOf(epicBadgeTextMarker);
    check('Pass 6: epic-badge marker found', epicBadgeTextStart !== -1, true);
    const epicBadgeTextContent = epicBadgeTextStart === -1 ? null :
        liveEpicBadgeTextHtml.slice(
            epicBadgeTextStart + epicBadgeTextMarker.length,
            liveEpicBadgeTextHtml.indexOf('</div>', epicBadgeTextStart)
        ).trim();
    assertElementContentNotInjectable('LIVE renderDayItems() epic badge text (Pass 6, truncateTitle composition)',
        epicBadgeTextContent, /* mustBreakOut */ false);

    // Pass 7 (5th round, BLOCKING sibling fix) -- external-event branch's
    // `${truncateTitle(item.title, 25)}` content, same <img>-tag payload.
    renderDayItems.__setCalendarState({
        cachedEpics: [], cachedItems: [],
        showExternalEvents: true,
        externalEvents: [{
            start: '2026-01-01T09:00:00', title: HOSTILE_ELEMENT_CONTENT_TITLE, source: null,
        }],
    });
    const liveExternalTruncHtml = renderDayItems.renderDayItems(new Date('2026-01-01T00:00:00'));
    check('LIVE renderDayItems(): Pass 7 external-event truncated-content day item was rendered (non-empty)', liveExternalTruncHtml.length > 0, true);
    const syncBadgeCloseMarker = '\u21bb</span>';
    const syncBadgeCloseIdx = liveExternalTruncHtml.indexOf(syncBadgeCloseMarker);
    check('Pass 7: sync-badge close marker found', syncBadgeCloseIdx !== -1, true);
    const externalTruncContent = syncBadgeCloseIdx === -1 ? null :
        liveExternalTruncHtml.slice(
            syncBadgeCloseIdx + syncBadgeCloseMarker.length,
            liveExternalTruncHtml.indexOf('</div>', syncBadgeCloseIdx)
        ).trim();
    assertElementContentNotInjectable('LIVE renderDayItems() external-event truncated content (Pass 7, truncateTitle composition)',
        externalTruncContent, /* mustBreakOut */ false);

    // Pass 8 (5th round, BLOCKING [UX] regression, XACA-1005-020) -- a
    // NUMERIC item.title of 0 must render "0" in row2, matching what the
    // SAME field's title="..." attribute (escapeAttr) already renders,
    // rather than the empty string escapeHtml's falsy guard used to produce.
    renderDayItems.__setCalendarState({
        cachedEpics: [],
        cachedItems: [{
            id: 'ITEM-ZERO', dueDate: '2026-01-01', title: 0,
            priority: 'medium', status: 'todo', epicId: null, epicName: null, subitemCount: 0,
        }],
    });
    const liveZeroHtml = renderDayItems.renderDayItems(new Date('2026-01-01T00:00:00'));
    check('LIVE renderDayItems(): Pass 8 numeric-0-title day item was rendered (non-empty)', liveZeroHtml.length > 0, true);
    const liveZeroRow2 = extractElementContent(liveZeroHtml, '<div class="calendar-item-row2">', '</div>');
    check('LIVE renderDayItems(): Pass 8 row2 renders "0" for a numeric-0 title (not blank)', liveZeroRow2, '0');
    const liveZeroTag = extractOpeningTag(liveZeroHtml, '<div', 'data-item-id="ITEM-ZERO"');
    check('LIVE renderDayItems(): Pass 8 title="..." attribute ALSO renders "0" (both renderings of the same field now agree)',
        liveZeroTag !== null && /title="ITEM-ZERO: 0 \(click to navigate\)"/.test(liveZeroTag), true);
}


// ===========================================================================
// 5th ROUND (PR #795 gate findings, standalone/fixture-level coverage) --
// composition-order proof for truncateTitle(), showMergeDialog() dueDate
// sinks, and showEpicAssignModal()'s bare data-epic-id.
// ===========================================================================

// --- BLOCKING: escapeHtml(truncateTitle(x, n)) vs truncateTitle(escapeHtml(x), n) ---
//
// Payload engineered so escaping BEFORE truncation lands the cut exactly
// inside the "&lt;" entity truncateTitle's raw '<' becomes, dropping only
// the terminating ';' and leaving a DANGLING "&lt" -- which HTML5's legacy
// named-character-reference table (the same backward-compatibility list
// that recognises "&amp"/"&gt"/"&quot" etc. without a semicolon) still
// decodes back to a raw "<" in text content, regardless of what follows.
// Escaping AFTER truncation cannot produce this: truncation happens on the
// plain raw string, and escapeHtml() then emits ONE complete substitution
// per metacharacter in the (already length-bounded) result -- there is no
// point at which a partial entity could exist to be cut, because nothing is
// cut after escaping runs.
const MID_ENTITY_PAYLOAD = 'A'.repeat(15) + '<X'; // escapeHtml -> 15 A's + "&lt;X" (20 chars)
const MID_ENTITY_MAX_LENGTH = 19; // truncateTitle(escapeHtml(payload), 19) severs "&lt;" to a dangling "&lt"

/** A minimal WHATWG "legacy, no-semicolon" named-character-reference
 * decoder, covering only the three entities escapeHtml() can ever produce
 * (amp/lt/gt -- it does not escape quotes). This is not a general HTML
 * entity decoder; it exists solely to demonstrate the one failure mode named
 * in this finding: per the WHATWG spec's named-character-reference table,
 * "lt"/"gt"/"amp" (among others) are recognised WITHOUT a trailing
 * semicolon for legacy compatibility, in text content, regardless of what
 * character follows. */
function decodeLegacyNoSemicolonEntities(s) {
    return s.replace(/&(amp|lt|gt);?/g, (_, name) => ({ amp: '&', lt: '<', gt: '>' }[name]));
}

/** A "complete" &-sequence here is exactly one escapeHtml() can produce:
 * &amp; / &lt; / &gt;, always semicolon-terminated. Anything else starting
 * with & is a dangling fragment. */
function assertNoIncompleteEntity(label, s) {
    check(`${label}: no dangling/incomplete HTML entity present`,
        /&(?!amp;|lt;|gt;)/.test(s), false);
}

function checkTruncateCompositionOrder(label, rawPayload, maxLength) {
    const wrongOrder = truncateTitle(escapeHtml(rawPayload), maxLength);
    const rightOrder = escapeHtml(truncateTitle(rawPayload, maxLength));

    check(`${label}: WRONG order (truncate-then-escape) DOES produce a dangling entity fragment`,
        /&(?!amp;|lt;|gt;)/.test(wrongOrder), true);
    assertNoIncompleteEntity(`${label}: RIGHT order (escape-then-truncate)`, rightOrder);

    // Illustrative, not the sole proof: decode the WRONG order's output the
    // way a browser's legacy no-semicolon matching would, showing a raw "<"
    // reappears in what would actually render -- the "manufactures the
    // injection" claim made concrete. (The RIGHT order's output also decodes
    // to contain "<", but that is the ORDINARY, INTENDED decoding of a
    // complete "&lt;" the truncated raw text legitimately contained --
    // the dangling-entity assertions above are what distinguish "manufactured"
    // from "intended".)
    const wrongDecoded = decodeLegacyNoSemicolonEntities(wrongOrder);
    check(`${label}: WRONG order's dangling entity DECODES BACK to a raw "<" once rendered`,
        wrongDecoded.indexOf('<') !== -1, true);
}

checkTruncateCompositionOrder('COMPOSITION ORDER (mid-entity payload, fixture-level)', MID_ENTITY_PAYLOAD, MID_ENTITY_MAX_LENGTH);

// POSITIVE CONTROL, general case: for ANY payload/length, escapeHtml(truncateTitle(...))
// must never produce a dangling entity -- not just for the one crafted
// payload above. Escaping is the LAST step in the correct order, so this
// holds structurally regardless of where the cut falls.
[
    ['short benign', 'hello world', 20],
    ['exact boundary', 'A'.repeat(19) + '<', 20],
    ['long with multiple metacharacters', '<b>&"'.repeat(10), 15],
].forEach(([label, payload, maxLength]) => {
    assertNoIncompleteEntity(`POSITIVE CONTROL (general case: ${label})`, escapeHtml(truncateTitle(payload, maxLength)));
});

// truncateTitle()'s own null/undefined guard (or lack of one): `title.length`
// throws on null/undefined with no guard in truncateTitle() itself. Verified
// via grep (see lcars.js) that truncateTitle() has exactly TWO callers in
// the whole file, both inside renderDayItems(), and both are now guarded at
// the CALL SITE with `String(x ?? '')` -- so truncateTitle() itself never
// receives null/undefined from either of its only two callers. Decision:
// NOT hardening truncateTitle()'s own body, because (a) the call-site guard
// already closes the gap for both real callers, and (b) doing so anyway
// would be an unrequested, unverified change to a shared helper for a
// problem that does not reach it. This assertion documents that
// truncateTitle() DOES still throw if called directly with null/undefined
// (i.e., confirms the guard lives at the call site, not inside the
// function, so a reader does not mistake this test suite's passing as
// truncateTitle() itself having been hardened).
check('truncateTitle() itself still has no null/undefined guard (by design -- guarded at both call sites instead)',
    (() => { try { truncateTitle(null, 10); return 'did not throw'; } catch (e) { return e instanceof TypeError ? 'threw TypeError' : `threw ${e.constructor.name}`; } })(),
    'threw TypeError');

// --- Source-level locks: composition order + null-guard call sites. ---
const epicBadgeTruncAssignment = source.match(
    /<span class="epic-badge">E<\/span> \$\{(\w+)\((\w+)\(String\(displayTitle \?\? ''\), 20\)\)\}/
);
check('source: epic-badge truncateTitle statement located in lcars.js (Pass 6)', !!epicBadgeTruncAssignment, true);
if (epicBadgeTruncAssignment) {
    check('source: epic-badge wraps the OUTER call with escapeHtml (correct composition order)',
        epicBadgeTruncAssignment[1], 'escapeHtml');
    check('source: epic-badge wraps the INNER call with truncateTitle (correct composition order)',
        epicBadgeTruncAssignment[2], 'truncateTitle');
}

const externalTruncAssignment = source.match(
    /\$\{(\w+)\((\w+)\(String\(item\.title \?\? ''\), 25\)\)\}/
);
check('source: external-event truncateTitle statement located in lcars.js (Pass 7)', !!externalTruncAssignment, true);
if (externalTruncAssignment) {
    check('source: external-event content wraps the OUTER call with escapeHtml (correct composition order)',
        externalTruncAssignment[1], 'escapeHtml');
    check('source: external-event content wraps the INNER call with truncateTitle (correct composition order)',
        externalTruncAssignment[2], 'truncateTitle');
}

const row2ZeroGuardAssignment = source.match(
    /<div class="calendar-item-row2">\$\{escapeHtml\(String\(item\.title \?\? ''\)\)\}<\/div>/
);
check('source: row2 statement uses the nullish-safe String(item.title ?? \'\') guard (Pass 8, XACA-1005-020)',
    !!row2ZeroGuardAssignment, true);

// ---------------------------------------------------------------------------
// XACA-1005-021 -- showMergeDialog()'s dueDate sinks, corrected comment +
// fix (defense-in-depth: sink determines the escaper, not demonstrated
// live reachability -- see the source comment in lcars.js for the full
// reachability analysis, including the separate, NOT-fixed-here finding in
// renderConflictItem()).
// ---------------------------------------------------------------------------

const HOSTILE_DUE_DATE_JS_STRING = "'); alert(5); //";
// Reuses HOSTILE_ATTR_TITLE's exact shape (not a distinct payload):
// assertMergeTitleInputAttributeShape() is the SAME helper SITE 5's
// merge-title input test uses, hardcoded to check for the 'x=' tail
// marker and an 'onmouseover=' injected attribute name. Reusing the
// identical payload here is safe (no marker-collision risk, unlike the
// SITE 7 class+title case) because this test targets a COMPLETELY
// SEPARATE <input id="merge-duedate"> element, with localTitle/
// externalTitle set to benign strings in this same render call.
const HOSTILE_DUE_DATE_ATTR = HOSTILE_ATTR_TITLE;

function runXaca1005021MergeDialogDueDateTests() {
    let bound;
    try {
        const slices = [
            extractFunction('escapeAttr'),
            extractFunction('jsAttrEscape'),
            extractFunction('showMergeDialog'),
        ].join('\n\n');

        const preamble =
            'function escapeHtml(t) { if (!t) return ""; return String(t)' +
            '.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }\n' +
            'var __lastAppended = null;\n' +
            'var __conflictItemStub = null;\n' +
            'function __setConflictItemStub(values) {\n' +
            '  __conflictItemStub = {\n' +
            '    querySelector: function (sel) {\n' +
            '      if (sel === ".local-version .field-value:nth-of-type(1)") return { textContent: values.localTitle };\n' +
            '      if (sel === ".local-version .field-value:nth-of-type(2)") return { textContent: values.localDueDate };\n' +
            '      if (sel === ".external-version .field-value:nth-of-type(1)") return { textContent: values.externalTitle };\n' +
            '      if (sel === ".external-version .field-value:nth-of-type(2)") return { textContent: values.externalDueDate };\n' +
            '      if (sel === ".conflict-actions") return { appendChild: function (el) { __lastAppended = el; } };\n' +
            '      throw new Error("unstubbed conflictItem.querySelector: " + sel);\n' +
            '    }\n' +
            '  };\n' +
            '}\n' +
            'var document = {\n' +
            '  querySelector: function () { return __conflictItemStub; },\n' +
            '  createElement: function () { return { className: "", innerHTML: "" }; }\n' +
            '};\n';

        // eslint-disable-next-line no-new-func
        const factory = new Function(
            preamble + slices +
            '\nreturn { showMergeDialog, __setConflictItemStub, __getLastAppended: function () { return __lastAppended; } };'
        );
        bound = factory();
    } catch (e) {
        fail(`XACA-1005-021 live extraction/setup failed: ${e.message}`);
        return;
    }

    // Pass A: JS-string-breakout payload for the due-date suggestion buttons.
    bound.__setConflictItemStub({
        localTitle: 'benign local title', externalTitle: 'benign external title',
        localDueDate: HOSTILE_DUE_DATE_JS_STRING, externalDueDate: HOSTILE_DUE_DATE_JS_STRING,
    });
    bound.showMergeDialog('ITEM-DUE-1', 0);
    const dueJsStringHtml = bound.__getLastAppended() && bound.__getLastAppended().innerHTML;
    check('LIVE showMergeDialog(): due-date JS-string test dialog was appended (non-empty innerHTML)',
        !!dueJsStringHtml && dueJsStringHtml.length > 0, true);
    if (dueJsStringHtml) {
        checkJsStringAssignmentIntegrity('LIVE showMergeDialog() due-date "Local" button (XACA-1005-021)',
            dueJsStringHtml, "document.getElementById('merge-duedate').value = '", "'\"", /* mustBreakOut */ false);
        checkJsStringAssignmentIntegrity('LIVE showMergeDialog() due-date "Calendar" button (XACA-1005-021)',
            dueJsStringHtml, "document.getElementById('merge-duedate').value = '", "'\"", /* mustBreakOut */ false);
    }

    // Pass B: raw-double-quote payload for the due-date <input value="...">.
    bound.__setConflictItemStub({
        localTitle: 'benign local title', externalTitle: 'benign external title',
        localDueDate: HOSTILE_DUE_DATE_ATTR, externalDueDate: 'None',
    });
    bound.showMergeDialog('ITEM-DUE-2', 0);
    const dueAttrHtml = bound.__getLastAppended() && bound.__getLastAppended().innerHTML;
    check('LIVE showMergeDialog(): due-date attribute test dialog was appended (non-empty innerHTML)',
        !!dueAttrHtml && dueAttrHtml.length > 0, true);
    if (dueAttrHtml) {
        const dueDateInputTag = extractInputTag(dueAttrHtml, 'merge-duedate');
        // assertMergeTitleInputAttributeShape's checks are attribute-name-
        // agnostic (they operate on whatever `value="..."` the tag carries),
        // so it is reused here for merge-duedate rather than merge-title.
        assertMergeTitleInputAttributeShape('LIVE showMergeDialog() due-date input (XACA-1005-021)',
            dueDateInputTag, /* mustBreakOut */ false);
    }
}
runXaca1005021MergeDialogDueDateTests();

// --- Source-level locks for the corrected "SIX sinks" comment + the two new fixes. ---
const dueDateInputAssignment = source.match(
    /<input type="date" id="merge-duedate" value="\$\{(\w+)\(localDueDate !== 'None' \? localDueDate : ''\)\}" \/>/
);
check('source: merge-duedate <input value=...> statement located in lcars.js (XACA-1005-021)',
    !!dueDateInputAssignment, true);
if (dueDateInputAssignment) {
    check('source: merge-duedate <input> value uses escapeAttr', dueDateInputAssignment[1], 'escapeAttr');
}

const dueDateLocalBtnAssignment = source.match(
    /document\.getElementById\('merge-duedate'\)\.value = '\$\{(\w+)\(localDueDate !== 'None' \? localDueDate : ''\)\}'/
);
check('source: merge-duedate "Local" button statement located in lcars.js (XACA-1005-021)',
    !!dueDateLocalBtnAssignment, true);
if (dueDateLocalBtnAssignment) {
    check('source: merge-duedate "Local" button uses jsAttrEscape', dueDateLocalBtnAssignment[1], 'jsAttrEscape');
}

const dueDateExternalBtnAssignment = source.match(
    /document\.getElementById\('merge-duedate'\)\.value = '\$\{(\w+)\(externalDueDate !== 'None' \? externalDueDate : ''\)\}'/
);
check('source: merge-duedate "Calendar" button statement located in lcars.js (XACA-1005-021)',
    !!dueDateExternalBtnAssignment, true);
if (dueDateExternalBtnAssignment) {
    check('source: merge-duedate "Calendar" button uses jsAttrEscape', dueDateExternalBtnAssignment[1], 'jsAttrEscape');
}

check('source: the corrected comment states "SIX sinks", not the stale "Three sinks" (XACA-1005-021)',
    /SIX sinks below, two escapers/.test(source), true);

// ---------------------------------------------------------------------------
// XACA-1005-023 -- showEpicAssignModal()'s bare data-epic-id="${epic.id}",
// fixed here (one line, in a function this ticket already touches) rather
// than deferred, distinct from the item.id/epic.id occurrences in
// renderDayItems() that ARE tracked under XACA-1013 and stay deliberately
// bare there.
// ---------------------------------------------------------------------------

const dataEpicIdAssignment = source.match(/data-epic-id="\$\{(\w+)\(epic\.id\)\}"\s*\n\s*onclick="selectEpicForItem/);
check('source: showEpicAssignModal data-epic-id statement located in lcars.js (XACA-1005-023)',
    !!dataEpicIdAssignment, true);
if (dataEpicIdAssignment) {
    check('source: showEpicAssignModal data-epic-id uses escapeAttr (XACA-1005-023)',
        dataEpicIdAssignment[1], 'escapeAttr');
}

async function runXaca1005023EpicSelectorDataEpicIdTest() {
    let showEpicAssignModal;
    try {
        const slices = [
            extractFunction('jsAttrEscape'),
            extractAsyncFunction('showEpicAssignModal'),
        ].join('\n\n');
        const preamble =
            'function escapeHtml(t) { if (!t) return ""; return String(t)' +
            '.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }\n' +
            'function escapeAttr(v) { return v === null || v === undefined ? "" : String(v)' +
            '.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/\'/g, "&#39;"); }\n' +
            'function pauseAutoRefresh() {}\n' +
            'function apiUrl(p) { return p; }\n' +
            'var __fetchEpicsResponse = { epics: [], colors: {} };\n' +
            'function __setFetchEpicsResponse(data) { __fetchEpicsResponse = data; }\n' +
            'function fetch(url) {\n' +
            '  return Promise.resolve({ ok: true, json: function () { return Promise.resolve(__fetchEpicsResponse); } });\n' +
            '}\n' +
            'var __listElStub = { innerHTML: "" };\n' +
            'var __modalStub = {\n' +
            '  dataset: {}, style: {},\n' +
            '  querySelector: function (sel) {\n' +
            '    if (sel === ".assign-item-id" || sel === ".assign-item-title") return { textContent: "" };\n' +
            '    throw new Error("unstubbed modal.querySelector: " + sel);\n' +
            '  }\n' +
            '};\n' +
            'var __els = { "epic-assign-modal": __modalStub, "epic-select-list": __listElStub };\n' +
            'var document = {\n' +
            '  getElementById: function (id) { return __els[id] || null; },\n' +
            '  body: { insertAdjacentHTML: function () { throw new Error("unexpected insertAdjacentHTML"); } }\n' +
            '};\n';
        // eslint-disable-next-line no-new-func
        const factory = new Function(
            preamble + slices +
            '\nreturn { showEpicAssignModal, __setFetchEpicsResponse, __getListHtml: function () { return __listElStub.innerHTML; } };'
        );
        showEpicAssignModal = factory();
    } catch (e) {
        fail(`XACA-1005-023 live extraction/setup failed: ${e.message}`);
        return;
    }

    // Uses 'data-hax=' rather than 'onmouseover=' as the breakout marker
    // deliberately: epic.id ALSO appears (correctly escaped, via
    // jsAttrEscape) inside the SAME tag's onclick attribute a few
    // characters later. Reusing 'onmouseover=' here would hit the exact
    // marker-collision bug already caught once for SITE 7 (class+title on
    // one tag) -- the escaped 'onmouseover=' text sitting inertly inside
    // onclick would false-positive the check below even with data-epic-id
    // correctly fixed. 'data-hax=' does not otherwise appear anywhere on
    // this tag, so it cannot collide.
    const hostileEpicId = 'EPIC" data-hax=alert(7) y="';
    showEpicAssignModal.__setFetchEpicsResponse({
        epics: [{ id: hostileEpicId, title: 'benign epic title', itemCount: 0 }],
        colors: {},
    });
    await showEpicAssignModal.showEpicAssignModal('ITEM-1', 'Item Title', 'academy', null);
    const html = showEpicAssignModal.__getListHtml();
    check('LIVE showEpicAssignModal(): epic list was rendered (non-empty), XACA-1005-023', html.length > 0, true);
    const optionTag = extractOpeningTag(html, '<div', 'class="epic-select-option');
    check('LIVE showEpicAssignModal(): epic-select-option tag located, XACA-1005-023', !!optionTag, true);
    if (optionTag) {
        const dataEpicIdMatch = optionTag.match(/data-epic-id="([^"]*)"/);
        check('LIVE showEpicAssignModal(): data-epic-id attribute present, XACA-1005-023', !!dataEpicIdMatch, true);
        if (dataEpicIdMatch) {
            check('LIVE showEpicAssignModal(): data-epic-id text is NOT truncated by the hostile raw quote (XACA-1005-023)',
                dataEpicIdMatch[1].indexOf('y=') !== -1, true);
        }
        // epic.id is interpolated TWICE on this tag -- data-epic-id AND
        // onclick's selectEpicForItem('${jsAttrEscape(epic.id)}', ...) --
        // so the hostile marker necessarily appears (correctly escaped) in
        // BOTH attribute values. Strip BOTH known attribute segments before
        // checking for a live breakout, or the onclick attribute's own
        // inert, correctly-escaped copy of the marker false-positives the
        // check -- the same class of marker-collision bug already caught
        // once for SITE 7's class+title dual-attribute tag, here caused by
        // a single field's dual interpolation rather than two fields.
        const onclickMatch = optionTag.match(/onclick="[^"]*"/);
        let tagWithoutKnownAttrs = optionTag;
        if (dataEpicIdMatch) tagWithoutKnownAttrs = tagWithoutKnownAttrs.replace(dataEpicIdMatch[0], '');
        if (onclickMatch) tagWithoutKnownAttrs = tagWithoutKnownAttrs.replace(onclickMatch[0], '');
        check('LIVE showEpicAssignModal(): data-hax= does NOT become a live attribute on the tag (XACA-1005-023)',
            /\bdata-hax\s*=/.test(tagWithoutKnownAttrs), false);
    }
}


// ===========================================================================
// 6th ROUND (PR #795 gate, follow-up to the coordinator's own reported-not-
// fixed finding from round 5) -- formatDate()'s catch-and-return-raw pattern
// is NOT narrowed to malformed date STRINGS; it is reachable with a
// NON-STRING dueDate (array, or an object with a hostile toString()), and
// this round proves that with the exact shape that bypasses the string
// path entirely. Also checks whether the pattern is a CLASS: formatTargetDate()
// (renderReleaseCard) shares the identical shape and is fixed alongside it.
// ===========================================================================
//
// MECHANISM, spelled out so a future reader does not have to re-derive it:
// parseLocalDate() calls `dateString.split('-')`, which THROWS for any
// non-string value (strings are the only thing `.split` exists on -- it
// does NOT throw for a malformed date STRING, which just produces NaN
// components and an Invalid Date, laundered safely). formatDate()'s
// `catch { return dateString; }` then returns the OFFENDING VALUE ITSELF,
// unstringified -- an array or object, not text. The consuming template
// literal (`${formatDate(x) || 'None'}`) coerces it via JS's implicit
// ToString AT THE INTERPOLATION POINT, which for an array joins its
// elements and for an object calls its toString() -- exactly the point
// where a single-element array `["<img ...>"]` or a `{ toString() {...} }`
// becomes live markup. XACA-1020 established handle_update_item applies
// client JSON fields with NO type validation at all, so a non-string
// dueDate is directly reachable, not a contrived edge case.
//
// THE TRAP THIS ROUND'S OWN INSTRUCTIONS NAME: a hostile STRING payload
// (e.g. a malformed date string containing "<img...>") tests NOTHING here,
// because the string path is already safe -- `.split('-')` never throws on
// a string, so formatDate() returns "Invalid Date" (a fixed, harmless
// literal), and a test built only on that payload shape would pass
// vacuously both before and after the fix. Every fixture and LIVE check
// below uses a NON-STRING payload (array, or object with hostile toString)
// specifically because that is the only shape that exercises the catch
// branch's raw-passthrough at all.

const HOSTILE_NONSTRING_ARRAY = ['<img src=x onerror=alert(1)>'];
const HOSTILE_NONSTRING_OBJECT = { toString() { return '<img src=x onerror=alert(2)>'; } };
const HOSTILE_TARGETDATE_ARRAY = ['<img src=x onerror=alert(3)>'];

// --- Fixture-level NEGATIVE/POSITIVE controls for the OLD vs NEW composition. ---
function buildOldDueDateField(dueDate) {
    return `<div class="field-value">${formatDate(dueDate) || 'None'}</div>`;
}
function buildFixedDueDateField(dueDate) {
    return `<div class="field-value">${escapeHtml(String(formatDate(dueDate) ?? 'None'))}</div>`;
}

function assertDueDateFieldNotInjectable(label, html, mustBreakOut) {
    const content = extractElementContent(html, '<div class="field-value">', '</div>');
    check(`${label}: field-value content located`, content !== null, true);
    if (content === null) return;
    check(`${label}: hostile <img> ${mustBreakOut ? 'DOES' : 'does NOT'} introduce a raw element (literal, unescaped '<img' substring)`,
        content.indexOf('<img') !== -1, mustBreakOut);
    if (!mustBreakOut) {
        check(`${label}: the hostile '<' survives as the &lt; entity, not raw`, content.indexOf('&lt;img') !== -1, true);
    }
}

[
    ['array payload', HOSTILE_NONSTRING_ARRAY],
    ['hostile-toString object payload', HOSTILE_NONSTRING_OBJECT],
].forEach(([label, payload]) => {
    assertDueDateFieldNotInjectable(`NEGATIVE CONTROL (pre-fix "|| \\'None\\'" composition, ${label})`,
        buildOldDueDateField(payload), /* mustBreakOut */ true);
    assertDueDateFieldNotInjectable(`POSITIVE CONTROL (fixed escapeHtml(String(... ?? 'None')) composition, ${label})`,
        buildFixedDueDateField(payload), /* mustBreakOut */ false);
});

// A STRING-ONLY payload must stay clean under BOTH compositions -- proving
// the fix does not merely coincidentally pass the non-string cases while
// silently breaking the (already-safe) string path, and documenting the
// exact trap this round's instructions named: this check alone would have
// been vacuous evidence of a fix.
const STRING_TRAP_PAYLOAD = '<img src=x onerror=alert(9)>'; // a STRING, not an array/object
check('STRING-ONLY payload (the vacuous-test trap): OLD composition is ALSO safe for a hostile STRING (proves the trap is real, not hypothetical)',
    buildOldDueDateField(STRING_TRAP_PAYLOAD).indexOf('<img') === -1, true);
check('STRING-ONLY payload: NEW composition remains safe too (fix does not regress the already-safe string path)',
    buildFixedDueDateField(STRING_TRAP_PAYLOAD).indexOf('<img') === -1, true);

// Absent-date and legitimate-date behavior must be UNCHANGED by the fix --
// verified against the real functions, not asserted from prose.
[
    ['a normal date string', '2026-01-01', 'Jan 1, 2026'],
    ['null (absent)', null, 'None'],
    ['undefined (absent)', undefined, 'None'],
    ['empty string (absent)', '', 'None'],
    ['a malformed date string', 'not-a-date', 'Invalid Date'],
].forEach(([label, input, expected]) => {
    check(`Legitimate-input parity (${label}): OLD and NEW compositions render IDENTICALLY`,
        extractElementContent(buildOldDueDateField(input), '<div class="field-value">', '</div>'),
        extractElementContent(buildFixedDueDateField(input), '<div class="field-value">', '</div>'));
    check(`Legitimate-input parity (${label}): renders the expected text "${expected}"`,
        extractElementContent(buildFixedDueDateField(input), '<div class="field-value">', '</div>'), expected);
});

// --- Source-level locks for both fixed call sites. ---
const localDueDateAssignment = source.match(
    /\$\{escapeHtml\(String\(formatDate\(localVersion\.dueDate\) \?\? 'None'\)\)\}/
);
check("source: renderConflictItem's local dueDate statement uses the fixed composition (6th round)",
    !!localDueDateAssignment, true);

const externalDueDateAssignment = source.match(
    /\$\{escapeHtml\(String\(formatDate\(externalVersion\.dueDate\) \?\? 'None'\)\)\}/
);
check("source: renderConflictItem's external dueDate statement uses the fixed composition (6th round)",
    !!externalDueDateAssignment, true);

const targetDateAssignment = source.match(/<span class="release-card-date">\$\{(\w+)\(targetDate\)\}<\/span>/);
check('source: renderReleaseCard targetDate statement located in lcars.js (6th round)', !!targetDateAssignment, true);
if (targetDateAssignment) {
    check('source: renderReleaseCard targetDate uses escapeHtml (6th round, formatTargetDate class fix)',
        targetDateAssignment[1], 'escapeHtml');
}

// --- LIVE integration: extract the REAL, currently-shipped renderConflictItem()
// and run it end-to-end with non-string dueDate payloads. renderConflictItem()
// is pure (verified: no document/window reference in its body), so no DOM
// stub is needed -- only its own dependencies (escapeHtml, formatDate,
// formatTimestamp, parseLocalDate). ---
function runXaca1005001Round6RenderConflictItemTests() {
    let bound;
    try {
        const slices = [
            extractFunction('parseLocalDate'),
            extractFunction('formatDate'),
            extractFunction('formatTimestamp'),
            extractFunction('renderConflictItem'),
        ].join('\n\n');
        const preamble = 'function escapeHtml(t) { if (!t) return ""; return String(t)' +
            '.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }\n';
        // eslint-disable-next-line no-new-func
        const factory = new Function(preamble + slices + '\nreturn { renderConflictItem };');
        bound = factory();
    } catch (e) {
        fail(`6th-round renderConflictItem live extraction failed: ${e.message}`);
        return;
    }

    function conflict(localDueDate, externalDueDate) {
        return {
            itemId: 'ITEM-CONFLICT-1',
            type: 'item',
            localVersion: { title: 'Local Title', dueDate: localDueDate, modifiedAt: '2026-01-01T00:00:00Z' },
            externalVersion: { title: 'External Title', dueDate: externalDueDate, modifiedAt: '2026-01-01T00:00:00Z' },
        };
    }

    // Pass 1: array payload on BOTH local and external dueDate.
    //
    // Checks operate on the SPECIFIC extracted field-value contents (index 1
    // = local Due Date, index 4 = external Due Date -- each version renders
    // Title/Due Date/Modified in that order), not a blanket scan of the
    // whole rendered card string. That distinction is load-bearing here, not
    // stylistic: the source-level comment explaining this fix (in lcars.js,
    // directly above the local Due Date div) contains the LITERAL prose
    // example text '<img src=x onerror=alert(1)>' as part of its own
    // explanation of the payload shape -- a blanket `wholeCardHtml.indexOf(
    // '<img')` check matches that comment text too and false-positives even
    // when the actual fix is completely correct, which is exactly what
    // happened once while writing this test (caught by re-inspecting the
    // real rendered output before assuming the fix was wrong).
    const arrayHtml = bound.renderConflictItem(conflict(HOSTILE_NONSTRING_ARRAY, HOSTILE_NONSTRING_ARRAY), 0);
    check('LIVE renderConflictItem(): array-payload conflict was rendered (non-empty)', arrayHtml.length > 0, true);
    const arrayFieldValues = [...arrayHtml.matchAll(/<div class="field-value">([\s\S]*?)<\/div>/g)].map(m => m[1]);
    check('LIVE renderConflictItem(): array payload -- at least 6 field-value divs matched (title/dueDate/modified x2 versions)',
        arrayFieldValues.length >= 6, true);
    check('LIVE renderConflictItem(): array payload -- local Due Date field-value has no raw, unescaped <img',
        (arrayFieldValues[1] || '').indexOf('<img') === -1, true);
    check('LIVE renderConflictItem(): array payload -- local Due Date field-value shows the escaped &lt;img entity',
        (arrayFieldValues[1] || '').indexOf('&lt;img') !== -1, true);
    check('LIVE renderConflictItem(): array payload -- external Due Date field-value has no raw, unescaped <img',
        (arrayFieldValues[4] || '').indexOf('<img') === -1, true);
    check('LIVE renderConflictItem(): array payload -- external Due Date field-value shows the escaped &lt;img entity',
        (arrayFieldValues[4] || '').indexOf('&lt;img') !== -1, true);

    // Pass 2: hostile-toString object payload, local only (external stays a
    // normal date, to also prove the fix does not touch the safe sibling).
    const objectHtml = bound.renderConflictItem(conflict(HOSTILE_NONSTRING_OBJECT, '2026-01-01'), 1);
    check('LIVE renderConflictItem(): hostile-toString-object conflict was rendered (non-empty)', objectHtml.length > 0, true);
    const objectFieldValues = [...objectHtml.matchAll(/<div class="field-value">([\s\S]*?)<\/div>/g)].map(m => m[1]);
    check('LIVE renderConflictItem(): hostile-toString-object payload -- local Due Date field-value has no raw <img',
        (objectFieldValues[1] || '').indexOf('<img') === -1, true);
    check('LIVE renderConflictItem(): hostile-toString-object payload -- local Due Date field-value survives as &lt;img',
        (objectFieldValues[1] || '').indexOf('&lt;img') !== -1, true);
    check('LIVE renderConflictItem(): the SAFE sibling (external Due Date, a real date string) still renders normally alongside the fix',
        (objectFieldValues[4] || '').indexOf('Jan 1, 2026') !== -1, true);

    // Pass 3: absent dueDate (null) on both sides -- must still render "None".
    const noneHtml = bound.renderConflictItem(conflict(null, null), 2);
    const noneFieldValues = [...noneHtml.matchAll(/<div class="field-value">([\s\S]*?)<\/div>/g)].map(m => m[1]);
    check('LIVE renderConflictItem(): absent dueDate (null) still renders "None" (legitimate-input parity, not just non-string safety)',
        noneFieldValues.filter(v => v === 'None').length >= 2, true);
}
runXaca1005001Round6RenderConflictItemTests();

// --- LIVE integration: the ALREADY-EXTRACTED renderReleaseCard() (top-level
// factory above, now also carrying formatTargetDate/parseLocalDate) with a
// hostile-array targetDate. ---
function runXaca1005001Round6RenderReleaseCardTargetDateTest() {
    const hostileRelease = {
        id: 'REL-TARGETDATE-1', name: 'Target Date Test Release', status: 'active',
        platforms: { other: { environment: 'DEV' } }, targetDate: HOSTILE_TARGETDATE_ARRAY,
    };
    const html = renderReleaseCard(hostileRelease);
    check('LIVE renderReleaseCard(): hostile-targetDate release was rendered (non-empty), 6th round', html.length > 0, true);
    const dateSpanContent = extractElementContent(html, '<span class="release-card-date">', '</span>');
    check('LIVE renderReleaseCard(): release-card-date span located, 6th round', dateSpanContent !== null, true);
    if (dateSpanContent !== null) {
        check('LIVE renderReleaseCard(): hostile <img> does NOT introduce a raw element in release-card-date (6th round)',
            dateSpanContent.indexOf('<img') !== -1, false);
        check('LIVE renderReleaseCard(): the hostile "<" survives as the &lt; entity in release-card-date (6th round)',
            dateSpanContent.indexOf('&lt;img') !== -1, true);
    }

    // Legitimate-input parity: a normal targetDate must still render its
    // formatted form, unaffected by the fix.
    const normalRelease = {
        id: 'REL-TARGETDATE-2', name: 'Normal Target Date Release', status: 'active',
        platforms: { other: { environment: 'DEV' } }, targetDate: '2026-01-01',
    };
    const normalHtml = renderReleaseCard(normalRelease);
    const normalDateSpanContent = extractElementContent(normalHtml, '<span class="release-card-date">', '</span>');
    check('LIVE renderReleaseCard(): a normal targetDate still renders its formatted text (legitimate-input parity, 6th round)',
        normalDateSpanContent !== null && /^[A-Za-z]{3} \d{1,2}/.test(normalDateSpanContent), true);
}
runXaca1005001Round6RenderReleaseCardTargetDateTest();


// ===========================================================================
// 7th ROUND (PR #795 gate) -- two more live element-content injections in
// renderReleaseCard(), found by the reviewer ~10 lines from the
// formatTargetDate fix this same ticket already made in this same function,
// PLUS a harness-fidelity bug (BLOCKING 2 above the source fixes): the
// suite's escapeHtml() stand-in used a NULLISH guard (`t == null`) while the
// REAL escapeHtml() in lcars.js uses a FALSY guard (`if (!text) return ''`).
// For item.title = 0 the real function returns '' -- that IS the XACA-1005-020
// [UX] bug fixed two rounds ago -- but the stand-in returned "0", so every
// LIVE Pass-8 assertion built on that stand-in was STRUCTURALLY INCAPABLE of
// catching a regression of that exact fix. Fixed: all 8 copies of the
// stand-in (7 string-preamble copies inside `new Function(...)` factories,
// plus the one standalone top-level `function escapeHtml` used by SITE 1's
// fixture builders) now read `if (!t) return ''; return String(t)...`,
// matching the real function's guard exactly. Proof this round's own
// requirements demand -- fail-before/pass-after on the HARNESS FIX ITSELF,
// not just on new source fixes -- is in the CHANGELOG.md entry (a scratch
// revert of the row2 fix, run against the now-faithful stand-in, sends the
// LIVE assertion red on its own, with no source-regex lock needed).
// ===========================================================================

const HOSTILE_PLATFORM_KEY = '<img src=x onerror=alert(1)>';
const HOSTILE_PLATFORM_VERSION = '<img src=x onerror=alert(2)>';

// --- Fixture-level NEGATIVE/POSITIVE controls, using the REAL extracted
// getPlatformName() (its raw-passthrough branch for an unmapped key is the
// exact mechanism under test) and the REAL (now-faithful) escapeHtml(). ---
function buildOldPlatformInfo(key, version) {
    return `<span class="platform-name">${getPlatformName(key)}</span><span class="platform-version">${version || '1.0.0'}</span>`;
}
function buildFixedPlatformInfo(key, version) {
    return `<span class="platform-name">${escapeHtml(getPlatformName(key))}</span><span class="platform-version">${escapeHtml(String(version || '1.0.0'))}</span>`;
}

function assertPlatformSpanNotInjectable(label, html, spanClass, mustBreakOut) {
    const content = extractElementContent(html, `<span class="${spanClass}">`, '</span>');
    check(`${label}: ${spanClass} content located`, content !== null, true);
    if (content === null) return;
    check(`${label}: ${spanClass} -- hostile <img> ${mustBreakOut ? 'DOES' : 'does NOT'} introduce a raw element`,
        content.indexOf('<img') !== -1, mustBreakOut);
    if (!mustBreakOut) {
        check(`${label}: ${spanClass} -- the hostile '<' survives as the &lt; entity, not raw`,
            content.indexOf('&lt;img') !== -1, true);
    }
}

// getPlatformName()'s raw-passthrough branch is confirmed live before it is
// relied on: an unmapped key must NOT resolve through the known-names map.
check("PRECONDITION: getPlatformName()'s known-names map does not happen to contain the hostile test key (else this round's fixture would test nothing)",
    ['ios', 'android', 'firebase', 'web', 'other'].includes(HOSTILE_PLATFORM_KEY.toLowerCase()), false);

assertPlatformSpanNotInjectable('NEGATIVE CONTROL (pre-fix raw platform-name, 7th round)',
    buildOldPlatformInfo(HOSTILE_PLATFORM_KEY, '1.0.0'), 'platform-name', /* mustBreakOut */ true);
assertPlatformSpanNotInjectable('POSITIVE CONTROL (escapeHtml platform-name, 7th round)',
    buildFixedPlatformInfo(HOSTILE_PLATFORM_KEY, '1.0.0'), 'platform-name', /* mustBreakOut */ false);
assertPlatformSpanNotInjectable('NEGATIVE CONTROL (pre-fix raw platform-version, 7th round)',
    buildOldPlatformInfo('ios', HOSTILE_PLATFORM_VERSION), 'platform-version', /* mustBreakOut */ true);
assertPlatformSpanNotInjectable('POSITIVE CONTROL (escapeHtml platform-version, 7th round)',
    buildFixedPlatformInfo('ios', HOSTILE_PLATFORM_VERSION), 'platform-version', /* mustBreakOut */ false);

// Legitimate-input parity: a MAPPED key's display label must be unaffected.
check('Legitimate-input parity: a mapped platform key ("ios") still renders "iOS" unchanged through escapeHtml() (7th round)',
    extractElementContent(buildFixedPlatformInfo('ios', '2.1.0'), '<span class="platform-name">', '</span>'), 'iOS');
check('Legitimate-input parity: a normal version string renders unchanged through escapeHtml() (7th round)',
    extractElementContent(buildFixedPlatformInfo('ios', '2.1.0'), '<span class="platform-version">', '</span>'), '2.1.0');

// --- Source-level locks. ---
const platformNameAssignment = source.match(/<span class="platform-name">\$\{(\w+)\(getPlatformName\(key\)\)\}<\/span>/);
check('source: platform-name statement located in lcars.js (7th round)', !!platformNameAssignment, true);
if (platformNameAssignment) {
    check('source: platform-name uses escapeHtml (element content, 7th round)', platformNameAssignment[1], 'escapeHtml');
}

const platformVersionAssignment = source.match(/<span class="platform-version">\$\{(\w+)\(String\(platform\.version \|\| '1\.0\.0'\)\)\}<\/span>/);
check('source: platform-version statement located in lcars.js (7th round)', !!platformVersionAssignment, true);
if (platformVersionAssignment) {
    check('source: platform-version uses escapeHtml (element content, 7th round)', platformVersionAssignment[1], 'escapeHtml');
}

// --- LIVE integration: the ALREADY-EXTRACTED renderReleaseCard() (top-level
// factory, which already carries getPlatformName + the now-faithful
// escapeHtml stand-in) with a hostile platform key AND a hostile version. ---
function runXaca1005001Round7PlatformInfoTest() {
    const hostileRelease = {
        id: 'REL-PLATFORM-1', name: 'Platform Info Test Release', status: 'active',
        platforms: { [HOSTILE_PLATFORM_KEY]: { environment: 'DEV', version: HOSTILE_PLATFORM_VERSION } },
    };
    const html = renderReleaseCard(hostileRelease);
    check('LIVE renderReleaseCard(): hostile platform key+version release was rendered (non-empty), 7th round', html.length > 0, true);
    assertPlatformSpanNotInjectable('LIVE renderReleaseCard() platform-name (7th round)', html, 'platform-name', /* mustBreakOut */ false);
    assertPlatformSpanNotInjectable('LIVE renderReleaseCard() platform-version (7th round)', html, 'platform-version', /* mustBreakOut */ false);

    // Legitimate-input parity against the REAL function: a normal platform
    // must still render its normal label/version, unaffected by the fix.
    const normalRelease = {
        id: 'REL-PLATFORM-2', name: 'Normal Platform Release', status: 'active',
        platforms: { ios: { environment: 'PROD', version: '3.4.1' } },
    };
    const normalHtml = renderReleaseCard(normalRelease);
    check('LIVE renderReleaseCard(): a mapped platform key ("ios") still renders "iOS" (legitimate-input parity, 7th round)',
        extractElementContent(normalHtml, '<span class="platform-name">', '</span>'), 'iOS');
    check('LIVE renderReleaseCard(): a normal version string still renders unchanged (legitimate-input parity, 7th round)',
        extractElementContent(normalHtml, '<span class="platform-version">', '</span>'), '3.4.1');
}
runXaca1005001Round7PlatformInfoTest();

function finalize() {
    if (failures > 0) {
        console.error(`\n${failures} test(s) failed.`);
        process.exit(1);
    }
    console.log('\nAll XACA-1005-001 escaper-breakout tests passed (crTitle, epic selector, merge dialog x3).');
}

runSite3to5MergeDialogTests();
runSite6And7CalendarDayTests();
Promise.all([runSite2EpicSelectorTests(), runXaca1005023EpicSelectorDataEpicIdTest()]).then(finalize).catch((e) => {
    console.error(`FAIL: uncaught error in SITE 2 (epic selector) tests — ${e.stack || e}`);
    process.exit(1);
});
