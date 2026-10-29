#!/usr/bin/env node
/**
 * XACA-1641 (Test round 1): the PR-EXEMPT tag in the LCARS release view renders an operator-typed
 * free-text reason (`kb-backlog no-pr --reason`). It must be inert: no quote can break out of the
 * title attribute, no `<` can open a tag. Extracts buildReleaseItemExemptTag / escapeHtml /
 * escapeAttr from lcars.js by brace matching (the file has top-level DOM calls, so it is not
 * require()d) and runs them with a DOM stub that escapes exactly as a browser's
 * textContent -> innerHTML does (& < > only, NOT quotes).
 *
 * Run: node lcars-ui/tests/test-xaca-1641-exempt-tag-inert.js
 */
'use strict';
const fs = require('fs');
const path = require('path');

const source = fs.readFileSync(path.join(__dirname, '..', 'js', 'lcars.js'), 'utf8');

function extractFn(name) {
    const start = source.indexOf(`function ${name}(`);
    if (start === -1) { console.error(`FAIL: function ${name} not found in lcars.js`); process.exit(1); }
    let i = source.indexOf('{', start), depth = 0;
    for (; i < source.length; i++) {
        if (source[i] === '{') depth++;
        else if (source[i] === '}' && --depth === 0) break;
    }
    return source.slice(start, i + 1);
}

const document = {
    createElement() {
        let t = '';
        return {
            set textContent(v) { t = String(v); },
            get innerHTML() { return t.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); },
        };
    },
};
// eslint-disable-next-line no-new-func
const build = new Function('document',
    [extractFn('escapeHtml'), extractFn('escapeAttr'), extractFn('buildReleaseItemExemptTag'),
     'return buildReleaseItemExemptTag;'].join('\n'))(document);

let failures = 0, total = 0;
function check(name, cond) {
    total++;
    if (cond) console.log(`ok - ${name}`); else { failures++; console.error(`FAIL: ${name}`); }
}

check('empty reason renders nothing', build('') === '' && build(null) === '' && build(undefined) === '');

const PAYLOADS = [
    'plain reason',
    'a"b', "a'b", 'a<b', 'a>b', 'a&b',
    'x" onmouseover="alert(document.cookie)',
    "x' onmouseover='alert(1)",
    '"><img src=x onerror=alert(1)>',
    '<script>alert(1)</script>',
];
for (const p of PAYLOADS) {
    const html = build(p);
    const m = html.match(/^<span class="release-item-pr-exempt" title="([^"]*)">(.*)<\/span>$/);
    check(`[${p}] has the exact span shape (title value contains no raw quote)`, !!m);
    if (!m) continue;
    check(`[${p}] title attribute has no raw " ' < >`, !/["'<>]/.test(m[1]));
    check(`[${p}] text node has no raw < >`, !/[<>]/.test(m[2]));
    check(`[${p}] exactly one open and one close tag (no injected element)`, (html.match(/</g) || []).length === 2);
    const openTag = html.slice(0, html.indexOf('>') + 1).replace(/title="[^"]*"/, 'title=T');
    check(`[${p}] open tag carries exactly the class and title attributes`, (openTag.match(/\s[\w-]+=/g) || []).length === 2);
}
check('title round-trips the reason for a benign string', build('plain reason').includes('title="plain reason"'));

console.log(`\n${total - failures}/${total} passed`);
process.exit(failures ? 1 : 0);
