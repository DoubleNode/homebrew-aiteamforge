#!/usr/bin/env node
//
//  test-xaca-1623-platform-labels.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * Regression tests for XACA-1623: getPlatformName() in lcars-ui/js/lcars.js
 * must prefer the team's declared releaseConfig.platforms[key].name over the
 * hardcoded ios/android/firebase/web/other map, so Academy's `ipados` and
 * `watchos` render "iPadOS" / "watchOS" instead of "Ipados" / "Watchos".
 *
 * Also pinned: the fallback map lookup is own-property only ('constructor'
 * must not resolve to Object.prototype.constructor), unusable config entries
 * fall through, the loader caches /api/release-config `platforms` (plain
 * object only), and the render sink still escapes a hostile declared name.
 *
 * LCARS_JS_PATH may point the suite at an alternate copy of lcars.js. It exists
 * ONLY so mutation sentinels can run against a scratch copy; unset by default.
 */

const fs = require('fs');
const path = require('path');

const LCARS_JS_PATH = process['env'].LCARS_JS_PATH ||
    path.join(__dirname, '..', 'js', 'lcars.js');
const source = fs.readFileSync(LCARS_JS_PATH, 'utf8');

let failures = 0;

function fail(msg) {
    failures++;
    console.error(`FAIL: ${msg}`);
}

/** Extract a top-level `function NAME(...) { ... }` by brace matching. */
function extractFunction(name) {
    const needle = `\nfunction ${name}(`;
    const start = source.indexOf(needle);
    if (start === -1) {
        throw new Error(
            `could not locate 'function ${name}(' in lcars.js — it may have been ` +
            `renamed, removed, or turned into an expression. Update this test.`
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

let getPlatformName;
let renderReleaseCard;
let setConfig;

try {
    const slices = [
        extractFunction('getPlatformName'),
        extractFunction('escapeAttr'),
        extractFunction('jsAttrEscape'),
        extractFunction('getReleaseEnvironments'),
        extractFunction('buildItemTagsHtml'),
        extractFunction('promoteStrandedBadgeHtml'),
        extractFunction('computeReleaseStageTestTotals'),
        extractFunction('releaseLifecycleHtml'),
        extractFunction('renderReleaseCard'),
        // renderReleaseCard -> renderArchiveAction -> isReleaseComplete chain
        extractFunction('renderArchiveAction'),
        extractFunction('isReleaseComplete'),
        extractFunction('getIncompletePlatforms'),
    ].join('\n\n');

    // Same stand-ins as test-xaca-1000: escapeHtml is DOM-backed in the browser,
    // so a faithful &/</> escaper replaces it; the sinks under test call it.
    const preamble = 'var releasePlatformConfig = {};\n' +
        'function __setConfig(c) { releasePlatformConfig = c; }\n' +
        'function escapeHtml(t) { return String(t == null ? "" : t)' +
        '.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }\n' +
        'var CANONICAL_STAGES = ["DEV", "QA", "ALPHA", "BETA", "GAMMA", "PROD"];\n' +
        'var releasesState = { expandedReleases: new Set() };\n';

    // eslint-disable-next-line no-new-func
    const factory = new Function(
        preamble + slices +
        '\nreturn { getPlatformName, renderReleaseCard, setConfig: __setConfig };'
    );
    ({ getPlatformName, renderReleaseCard, setConfig } = factory());
} catch (e) {
    console.error(`FAIL: ${e.message}`);
    process.exit(1);
}

function check(name, actual, expected) {
    if (actual === expected) {
        console.log(`ok - ${name}`);
    } else {
        fail(`${name} — expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
    }
}

function checkTrue(name, cond, detail) {
    if (cond) {
        console.log(`ok - ${name}`);
    } else {
        fail(`${name}${detail ? ' — ' + detail : ''}`);
    }
}

// --- config name wins --------------------------------------------------------
setConfig({
    ipados: { name: 'iPadOS', store: 'app-store' },
    watchos: { name: 'watchOS' },
    ios: { name: 'iPhone OS' },
});
check('config name wins: ipados -> iPadOS', getPlatformName('ipados'), 'iPadOS');
check('config name wins: watchos -> watchOS', getPlatformName('watchos'), 'watchOS');
check('config overrides built-in: ios -> iPhone OS', getPlatformName('ios'), 'iPhone OS');
check('built-in still used when not configured: android', getPlatformName('android'), 'Android');
check('built-in still used when not configured: other', getPlatformName('other'), 'Other');

// --- case --------------------------------------------------------------------
check('uppercase key IPADOS resolves via lowercase lookup', getPlatformName('IPADOS'), 'iPadOS');
check('mixed-case key WatchOS resolves via lowercase lookup', getPlatformName('WatchOS'), 'watchOS');
setConfig({ IPADOS: { name: 'Exact Case' }, ipados: { name: 'Lower Case' } });
check('exact-case key wins over lowercase key', getPlatformName('IPADOS'), 'Exact Case');

// --- fallbacks with empty config ---------------------------------------------
setConfig({});
check('empty config: ios -> iOS', getPlatformName('ios'), 'iOS');
check('empty config: android -> Android', getPlatformName('android'), 'Android');
check('empty config: ipados -> Ipados (title-case)', getPlatformName('ipados'), 'Ipados');
check('empty config: watchos -> Watchos (title-case)', getPlatformName('watchos'), 'Watchos');

// --- unusable entries fall through -------------------------------------------
const BAD_ENTRIES = [
    ['empty-string name', { name: '' }],
    ['whitespace-only name', { name: '   ' }],
    ['null name', { name: null }],
    ['numeric name', { name: 42 }],
    ['object name', { name: { x: 1 } }],
    ['missing name', { store: 'app-store' }],
    ['null entry', null],
    ['string entry', 'iPadOS'],
    ['numeric entry', 7],
];
BAD_ENTRIES.forEach(([label, entry]) => {
    setConfig({ ipados: entry, ios: entry });
    check(`${label}: ipados falls through to title-case`, getPlatformName('ipados'), 'Ipados');
    check(`${label}: ios falls through to built-in`, getPlatformName('ios'), 'iOS');
});
setConfig({ ipados: { name: ' iPadOS ' } });
check('whitespace-padded name is trimmed', getPlatformName('ipados'), 'iPadOS');
setConfig({ IPADOS: { name: '' }, ipados: { name: 'Fallback Lower' } });
check('blank exact-case entry falls to lowercase entry', getPlatformName('IPADOS'), 'Fallback Lower');

// --- prototype keys ----------------------------------------------------------
const PROTO_KEYS = ['toString', 'hasOwnProperty', 'valueOf', '__proto__', 'constructor'];
setConfig({});
check("empty config: 'constructor' -> Constructor", getPlatformName('constructor'), 'Constructor');
check("empty config: '__proto__' -> __proto__", getPlatformName('__proto__'), '__proto__');
PROTO_KEYS.forEach((k) => {
    check(`empty config: ${k} returns a string`, typeof getPlatformName(k), 'string');
});
check("empty config: 'toString' -> ToString", getPlatformName('toString'), 'ToString');
check("empty config: 'hasOwnProperty' -> HasOwnProperty", getPlatformName('hasOwnProperty'), 'HasOwnProperty');

setConfig({ ipados: { name: 'iPadOS' }, ios: { name: 'iPhone OS' } });
check("populated config: 'constructor' -> Constructor", getPlatformName('constructor'), 'Constructor');
check("populated config: '__proto__' -> __proto__", getPlatformName('__proto__'), '__proto__');
PROTO_KEYS.forEach((k) => {
    check(`populated config: ${k} returns a string`, typeof getPlatformName(k), 'string');
});
check("populated config: 'toString' -> ToString", getPlatformName('toString'), 'ToString');
// A config object whose prototype carries a name must not leak via inheritance.
setConfig(Object.create({ ghost: { name: 'Inherited' } }));
check('inherited (non-own) config entry is ignored', getPlatformName('ghost'), 'Ghost');
// An OWN "constructor" entry in config is a legitimate declaration.
setConfig(JSON.parse('{"constructor": {"name": "Ctor Platform"}}'));
check("own 'constructor' config entry is honoured", getPlatformName('constructor'), 'Ctor Platform');

// --- null / undefined key ----------------------------------------------------
setConfig({ ipados: { name: 'iPadOS' } });
check('null key -> empty string', getPlatformName(null), '');
check('undefined key -> empty string', getPlatformName(undefined), '');
check('empty-string key -> empty string', getPlatformName(''), '');

// --- loader wiring (static source-shape check) -------------------------------
const loaderStart = source.indexOf('async function loadReleases(');
checkTrue('loadReleases located in lcars.js', loaderStart !== -1);
const nextFn = source.slice(loaderStart + 1).search(/\n(?:async )?function /);
const loaderBody = loaderStart === -1 ? '' :
    source.slice(loaderStart, nextFn === -1 ? undefined : loaderStart + 1 + nextFn);
const okBranch = loaderBody.indexOf('if (configResponse.ok) {');
checkTrue('loadReleases has a configResponse.ok branch', okBranch !== -1);
const assignIdx = loaderBody.indexOf('releasePlatformConfig =');
checkTrue('loadReleases assigns releasePlatformConfig', assignIdx !== -1);
checkTrue('releasePlatformConfig assignment is inside the configResponse.ok branch',
    okBranch !== -1 && assignIdx > okBranch);
const assignStmt = assignIdx === -1 ? '' : loaderBody.slice(assignIdx, assignIdx + 300);
checkTrue('loader guards Array.isArray before caching platforms',
    /Array\.isArray\(configData\.platforms\)/.test(assignStmt));
checkTrue('loader guards typeof object before caching platforms',
    /typeof configData\.platforms === 'object'/.test(assignStmt));
checkTrue('loader resets to {} for non-object platforms', /:\s*\{\}\s*;/.test(assignStmt));
checkTrue('releasePlatformConfig is declared as a module-level let',
    /\nlet releasePlatformConfig = \{\};/.test(source));

// --- sink escaping through renderReleaseCard ---------------------------------
const HOSTILE = '<img src=x onerror=1>';
setConfig({ ipados: { name: HOSTILE } });
const cardHtml = renderReleaseCard({
    id: 'REL-TEST-1623',
    name: 'Platform label sink',
    status: 'active',
    platforms: { ipados: { environment: 'DEV', version: '1.0' } },
    items: [],
});
checkTrue('card renders a platform-name span', cardHtml.indexOf('platform-name') !== -1);
checkTrue('hostile config name is escaped in the card',
    cardHtml.indexOf('&lt;img src=x onerror=1&gt;') !== -1, 'escaped form not found');
checkTrue('hostile config name does not appear raw in the card',
    cardHtml.indexOf(HOSTILE) === -1, 'raw <img> tag leaked into card markup');

setConfig({ ipados: { name: 'iPadOS' } });
const cleanHtml = renderReleaseCard({
    id: 'REL-TEST-1623B',
    name: 'Platform label render',
    status: 'active',
    platforms: { ipados: { environment: 'DEV', version: '1.0' } },
    items: [],
});
checkTrue('card renders the configured label iPadOS', cleanHtml.indexOf('>iPadOS<') !== -1);
checkTrue('card does not render the title-cased key Ipados', cleanHtml.indexOf('Ipados') === -1);

if (failures > 0) {
    console.error(`\n${failures} test(s) failed.`);
    process.exit(1);
}
