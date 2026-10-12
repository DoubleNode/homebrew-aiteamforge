//
//  xaca-1065-loopback-guard.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1065-005: STATIC regression guard for the fleet-monitor/server wildcard-bind flake.
 *
 * Root cause (see tests/helpers/loopback-request.js): supertest `request(app)` binds the WILDCARD address but dials
 * 127.0.0.1, so on macOS a port held by a foreign process at 127.0.0.1 only can answer (or swallow) the request.
 * That only manifests on macOS under the right port collision, so this guard is structural and deterministic on
 * every OS: it reads the test sources and fails if a future suite reintroduces a wildcard bind.
 *
 *   a. nothing under tests/ imports `supertest` except helpers/loopback-request.js
 *   b. every `.listen(` CALL in tests/ names the host 127.0.0.1 (narrow, documented allowlist below)
 *   c. non-vacuity: the scan really saw the suite (floors below, derived from a counted run)
 *   d. the helper really binds 127.0.0.1 (and refuses to hand supertest anything else)
 *
 * The scan tokenizes (comments and string/template/regex literals are skipped as code), so prose mentioning
 * `app.listen(` or fixture strings never false-positive.
 */

const { test, describe } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const net = require('net');
const express = require('express');
const request = require('./helpers/loopback-request');

const TESTS_DIR = __dirname;
const HELPER_REL = 'helpers/loopback-request.js';
const FIX = 'see tests/helpers/loopback-request.js (XACA-1065): use `require(\'./helpers/loopback-request\')` and `.listen(0, \'127.0.0.1\')`';

// Non-vacuity floors, derived from a counted run on 2026-10-11 (this worktree):
//   find tests -name '*.js' | wc -l            -> 142 files scanned (incl. helpers + this guard)
//   the guard's own scan() (require() of the helper)  -> 51 importers (printed in the (c) test title)
// Floors sit just under the counts so the suite may shrink a little but a broken glob/path (0 files) cannot pass.
const MIN_FILES = 100;
const MIN_HELPER_IMPORTS = 40;

// Deliberate wildcard `.listen(` calls. Key = `<relative file>|<receiver>.listen(<args, tokens joined, string quotes dropped>)`, value = reason.
const LISTEN_ALLOWLIST = new Map([
    ['xaca-1065-loopback-request.test.js|wild.listen(P,()=>resolve(bound))', 'deliberately binds the WILDCARD to document the host behaviour (macOS: coexists with a 127.0.0.1-only holder; Linux: EADDRINUSE); closed immediately, no request is sent to it'],
]);

// ---- tiny JS tokenizer: ident / punct / string tokens with line numbers; comments dropped -----------------------
const REGEX_PREV = new Set(['(', ',', '=', ':', '[', '!', '&', '|', '?', '{', '}', ';', '+', '-', '*', '%', '<', '>', '~', '^', 'return', 'typeof', 'case', '=>']);

function tokenize(src) {
    const toks = [];
    let i = 0;
    let line = 1;
    const n = src.length;
    const push = (type, value, ln) => toks.push({ type, value, line: ln });
    while (i < n) {
        const c = src[i];
        if (c === '\n') { line++; i++; continue; }
        if (/\s/.test(c)) { i++; continue; }
        if (c === '/' && src[i + 1] === '/') { while (i < n && src[i] !== '\n') i++; continue; }
        if (c === '/' && src[i + 1] === '*') {
            i += 2;
            while (i < n && !(src[i] === '*' && src[i + 1] === '/')) { if (src[i] === '\n') line++; i++; }
            i += 2; continue;
        }
        if (c === '"' || c === "'" || c === '`') {
            const q = c; const ln = line; let v = ''; i++;
            let depth = 0; // template ${ } nesting (contents kept inside the literal, not tokenized)
            while (i < n) {
                const d = src[i];
                if (d === '\\') { v += src[i + 1] || ''; if (src[i + 1] === '\n') line++; i += 2; continue; }
                if (d === '\n') line++;
                if (q === '`' && d === '$' && src[i + 1] === '{') { depth++; v += '${'; i += 2; continue; }
                if (q === '`' && depth > 0 && d === '}') { depth--; v += d; i++; continue; }
                if (d === q && depth === 0) { i++; break; }
                v += d; i++;
            }
            push('string', v, ln); continue;
        }
        if (c === '/') {
            const prev = toks[toks.length - 1];
            const regexOk = !prev || (prev.type === 'punct' && REGEX_PREV.has(prev.value)) || (prev.type === 'ident' && REGEX_PREV.has(prev.value));
            if (regexOk) {
                let inClass = false; i++;
                while (i < n && src[i] !== '\n') {
                    if (src[i] === '\\') { i += 2; continue; }
                    if (src[i] === '[') inClass = true; else if (src[i] === ']') inClass = false;
                    else if (src[i] === '/' && !inClass) { i++; break; }
                    i++;
                }
                while (i < n && /[a-z]/i.test(src[i])) i++;
                push('string', '/regex/', line); continue;
            }
        }
        if (/[A-Za-z_$]/.test(c)) {
            let j = i + 1; while (j < n && /[\w$]/.test(src[j])) j++;
            push('ident', src.slice(i, j), line); i = j; continue;
        }
        if (/\d/.test(c)) {
            let j = i + 1; while (j < n && /[\w.]/.test(src[j])) j++;
            push('num', src.slice(i, j), line); i = j; continue;
        }
        if (c === '=' && src[i + 1] === '>') { push('punct', '=>', line); i += 2; continue; }
        push('punct', c, line); i++;
    }
    return toks;
}

function listJs(dir) {
    const out = [];
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, e.name);
        if (e.isDirectory()) out.push(...listJs(full));
        else if (e.isFile() && e.name.endsWith('.js')) out.push(full);
    }
    return out.sort();
}

// Findings for rule (a): supertest imports.
function findSupertestImports(toks) {
    const hits = [];
    const isSt = (t) => t && t.type === 'string' && /^supertest(\/|$)/.test(t.value);
    for (let k = 0; k < toks.length; k++) {
        const t = toks[k];
        if (t.type !== 'ident') continue;
        if ((t.value === 'require' || t.value === 'import') && toks[k + 1] && toks[k + 1].value === '(' && isSt(toks[k + 2])) hits.push(t.line);
        else if (t.value === 'from' && isSt(toks[k + 1])) hits.push(t.line);
        else if (t.value === 'import' && isSt(toks[k + 1])) hits.push(t.line); // side-effect import 'supertest'
    }
    return hits;
}

// Findings for rule (b): every `.listen(` call -> { line, argText, ok }.
function findListenCalls(toks, rel) {
    const calls = [];
    const declaresLoopback = toks.some((t, k) => t.value === 'LOOPBACK' && toks[k + 1] && toks[k + 1].value === '=' && toks[k + 2] && toks[k + 2].value === '127.0.0.1');
    for (let k = 1; k < toks.length - 1; k++) {
        if (!(toks[k].type === 'ident' && toks[k].value === 'listen' && toks[k - 1].value === '.' && toks[k + 1].value === '(')) continue;
        // collect top-level args up to the matching ')'
        const args = [[]]; let depth = 0; let j = k + 2;
        for (; j < toks.length; j++) {
            const v = toks[j].type === 'string' ? null : toks[j].value;
            if (v === '(' || v === '[' || v === '{') depth++;
            else if (v === ')' || v === ']' || v === '}') { if (depth === 0) break; depth--; }
            else if (v === ',' && depth === 0) { args.push([]); continue; }
            args[args.length - 1].push(toks[j]);
        }
        const isHost = (a) => a.length === 1 && ((a[0].type === 'string' && a[0].value === '127.0.0.1') ||
            // `LOOPBACK` counts ONLY in the helper, and only when that same file declares `const LOOPBACK = '127.0.0.1'`.
            (rel === HELPER_REL && declaresLoopback && a[0].type === 'ident' && a[0].value === 'LOOPBACK'));
        let ok = args.length >= 2 && isHost(args[1]);
        // `.listen({ port, host: '127.0.0.1' })`
        const o = args[0];
        if (!ok && o.length && o[0].value === '{') {
            ok = o.some((t, q) => t.value === 'host' && o[q + 1] && o[q + 1].value === ':' && o[q + 2] && o[q + 2].type === 'string' && o[q + 2].value === '127.0.0.1');
        }
        const argsText = args.map((a) => a.map((t) => t.value).join('')).join(',');
        const callSrc = `${toks[k - 2] && toks[k - 2].type === 'ident' ? toks[k - 2].value : ''}.listen(${argsText})`;
        calls.push({ line: toks[k].line, ok, callSrc, argsText });
        k = j;
    }
    return calls;
}

// One full scan of `dir`: returns everything the assertions need.
function scan(dir) {
    const files = listJs(dir);
    const result = { files: files.length, helperImporters: 0, supertestImports: [], badListens: [], listenCalls: 0, allowlistUsed: new Set() };
    for (const f of files) {
        const rel = path.relative(dir, f).split(path.sep).join('/');
        const toks = tokenize(fs.readFileSync(f, 'utf8'));
        if (toks.some((t, k) => t.type === 'string' && /(^|\/)helpers\/loopback-request$|^\.\/loopback-request$/.test(t.value) && toks[k - 1] && toks[k - 1].value === '(' && toks[k - 2] && toks[k - 2].value === 'require')) result.helperImporters++;
        if (rel !== HELPER_REL) for (const line of findSupertestImports(toks)) result.supertestImports.push(`${rel}:${line}`);
        for (const c of findListenCalls(toks, rel)) {
            result.listenCalls++;
            if (c.ok) continue;
            const key = `${rel}|${c.callSrc}`;
            if (LISTEN_ALLOWLIST.has(key)) { result.allowlistUsed.add(key); continue; }
            result.badListens.push(`${rel}:${c.line}  .listen(${c.argsText})`);
        }
    }
    return result;
}

const SCAN = scan(TESTS_DIR);

describe('XACA-1065 loopback guard: static scan of tests/', () => {
    test('(a) no test file imports supertest directly (only helpers/loopback-request.js may)', () => {
        assert.deepEqual(SCAN.supertestImports, [],
            `XACA-1065: direct supertest import binds the WILDCARD address and re-introduces the flake. ${FIX}\nOffending: ${SCAN.supertestImports.join(', ')}`);
    });

    test('(b) every .listen( call in tests/ passes the host 127.0.0.1', () => {
        assert.deepEqual(SCAN.badListens, [],
            `XACA-1065: wildcard .listen( in a test (binds ::, can collide with a foreign 127.0.0.1 holder on macOS). ${FIX}\nOffending:\n  ${SCAN.badListens.join('\n  ')}`);
    });

    test('(b) the allowlist has no stale entries (each entry is still needed)', () => {
        for (const key of LISTEN_ALLOWLIST.keys()) assert.ok(SCAN.allowlistUsed.has(key), `stale LISTEN_ALLOWLIST entry "${key}" -- remove it`);
    });

    test(`(c) non-vacuity: scan saw >= ${MIN_FILES} files, >= ${MIN_HELPER_IMPORTS} helper imports, and real listen calls (scanned ${SCAN.files} files, ${SCAN.helperImporters} importers, ${SCAN.listenCalls} listen calls)`, () => {
        assert.ok(SCAN.files >= MIN_FILES, `XACA-1065 guard is vacuous: only ${SCAN.files} .js files scanned under ${TESTS_DIR} (floor ${MIN_FILES}) -- broken path/glob?`);
        assert.ok(SCAN.helperImporters >= MIN_HELPER_IMPORTS, `XACA-1065 guard is vacuous: only ${SCAN.helperImporters} helper importers found (floor ${MIN_HELPER_IMPORTS})`);
        assert.ok(SCAN.listenCalls >= 5, `XACA-1065 guard is vacuous: only ${SCAN.listenCalls} .listen( calls recognised -- tokenizer broken?`);
    });

    test('scanner self-test: detects each violation form and ignores comments/strings (so the assertions above can fail)', () => {
        const st = (s) => findSupertestImports(tokenize(s)).length;
        for (const s of ["const r = require('supertest');", 'const r = require("supertest");', "import r from 'supertest';",
            "const r = await import('supertest');", "const r = require('supertest/lib/test');", "import 'supertest';"]) assert.equal(st(s), 1, s);
        assert.equal(st("// require('supertest')\n/* require('supertest') */ const s = \"require('supertest')\";"), 0);
        const ls = (s) => findListenCalls(tokenize(s), 'x.js').filter((c) => !c.ok).length;
        for (const s of ['a.listen()', 'a.listen(0)', 'a.listen(0, cb)', 'a.listen(port)', 'a.listen({ port: 0 })', 'a.listen(0, () => x(1, 2))', 'a.listen(0, HOST)', 'a.listen(0, LOOPBACK)']) assert.equal(ls(s), 1, s);
        for (const s of ["a.listen(0, '127.0.0.1')", "a.listen(0, '127.0.0.1', cb)", 'a.listen(p, "127.0.0.1", () => {})', "a.listen({ port: 0, host: '127.0.0.1' })",
            '// a.listen(0)\n/* a.listen(0) */ const s = "a.listen(0)"; const t = `a.listen(0)`;', 'a.listen = function () {}']) assert.equal(ls(s), 0, s);
    });
});

describe('XACA-1065 loopback guard: the helper really binds 127.0.0.1', () => {
    test('exports LOOPBACK === 127.0.0.1 and the helper source pins its listen to that constant', () => {
        assert.equal(request.LOOPBACK, '127.0.0.1');
        const toks = tokenize(fs.readFileSync(path.join(TESTS_DIR, HELPER_REL), 'utf8'));
        const calls = findListenCalls(toks, HELPER_REL);
        assert.ok(calls.length >= 1, 'helper has no .listen( call?');
        for (const c of calls) assert.ok(c.ok, `XACA-1065: helper ${HELPER_REL}:${c.line} .listen(${c.argsText}) is not pinned to 127.0.0.1`);
    });

    test('the server supertest is handed reports address 127.0.0.1 (observed from inside the request)', async () => {
        const app = express();
        let seen = null;
        app.get('/p', (req, res) => { seen = req.socket.server.address(); res.json({}); });
        await request(app).get('/p').expect(200);
        assert.ok(seen, 'handler never ran');
        assert.equal(seen.address, '127.0.0.1', `XACA-1065: request served by a server bound to ${JSON.stringify(seen)}`);
        assert.equal(seen.family, 'IPv4');
    });

    test('belt-and-braces: a non-loopback bind is refused with an XACA-1065 error and the server is closed', async () => {
        const origAddress = net.Server.prototype.address;
        const servers = [];
        net.Server.prototype.address = function () {
            servers.push(this);
            const a = origAddress.call(this);
            return a ? { ...a, address: '::' } : a; // pretend the kernel gave us the wildcard
        };
        try {
            await assert.rejects(() => request(express()).get('/x'), /XACA-1065 server bound to .*expected 127\.0\.0\.1/);
        } finally { net.Server.prototype.address = origAddress; }
        assert.ok(servers.length >= 1);
        for (const s of servers) assert.equal(s.listening, false, 'refused server left listening');
    });
});
