//
//  lcars-client-dom-stub.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * Minimal DOM shim + vm.Context loader for XACA-0983-013/014/015.
 *
 * The 5 LCARS client apps under fleet-monitor/server/public/{lcars,lcars2}/js/
 * are plain browser IIFEs -- no module.exports, no bundler, no jsdom
 * dependency in package.json. To unit-test createServiceOnlyLcarsCard(),
 * createTeamCard(), isLcarsTerminal(), and escapeHtml() without adding a new
 * heavy dependency, this loader:
 *
 *   1. Reads the real client file off disk (the actual shipped source, not
 *      a copy/paraphrase -- so these tests exercise the real defect and the
 *      real fix, not a re-implementation of either).
 *   2. Appends one line, immediately before the file's closing `})();`,
 *      that stashes the functions we need onto `window.__lcarsTestExports`
 *      (they are otherwise closed over by the IIFE and unreachable).
 *   3. Runs the patched source in a fresh vm.Context whose `document` /
 *      `window` are a hand-rolled stub -- just enough surface for these two
 *      functions' code paths (createElement, classList, setAttribute,
 *      addEventListener/dispatch, textContent->innerHTML text-node
 *      escaping per the WHATWG HTML fragment-serialization algorithm,
 *      window.open, window.location.origin). Nothing else in the file
 *      executes: everything else lives inside the DOMContentLoaded handler,
 *      which we register but never dispatch.
 *
 * escapeHtml()'s ONLY externally-observable behavior is
 * `div.textContent = x; return div.innerHTML;` -- a real browser escapes
 * `&`, the U+00A0 NBSP, `<`, and `>` in that round-trip (WHATWG HTML
 * "serialising HTML fragments" spec, text-node branch) and leaves quote
 * characters alone (they are only special inside an attribute value, not
 * inside element content). textContentToInnerHtml() below implements
 * exactly that rule -- not a stand-in escaper of the test's own invention.
 */

const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const PUBLIC_ROOT = path.join(__dirname, '..', '..', 'public');

// WHATWG "serialising HTML fragments" text-node escaping -- what a real
// browser produces when you set .textContent then read .innerHTML back.
function textContentToInnerHtml(text) {
    return String(text)
        .replace(/&/g, '&amp;')
        .replace(/ /g, '&nbsp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;');
}

class FakeClassList {
    constructor(el) {
        this._el = el;
    }
    add(cls) {
        const current = this._el.className ? this._el.className.split(/\s+/).filter(Boolean) : [];
        if (!current.includes(cls)) {
            current.push(cls);
            this._el.className = current.join(' ');
        }
    }
    contains(cls) {
        return (this._el.className || '').split(/\s+/).filter(Boolean).includes(cls);
    }
}

class FakeElement {
    constructor(tag) {
        this.tagName = String(tag || 'div').toUpperCase();
        this.className = '';
        this._innerHTML = '';
        this._attrs = new Map();
        this._listeners = new Map();
        this.style = {};
        this.title = '';
        this.classList = new FakeClassList(this);
        this.children = [];
    }
    set innerHTML(v) {
        this._innerHTML = v;
    }
    get innerHTML() {
        return this._innerHTML;
    }
    set textContent(v) {
        this._textContent = v;
        // Mirrors a real browser: after setting textContent, innerHTML
        // reads back the escaped serialization of that one text node.
        this._innerHTML = textContentToInnerHtml(v);
    }
    get textContent() {
        return this._textContent || '';
    }
    setAttribute(name, value) {
        this._attrs.set(name, String(value));
    }
    getAttribute(name) {
        return this._attrs.has(name) ? this._attrs.get(name) : null;
    }
    removeAttribute(name) {
        this._attrs.delete(name);
    }
    hasAttribute(name) {
        return this._attrs.has(name);
    }
    addEventListener(type, handler) {
        if (!this._listeners.has(type)) this._listeners.set(type, []);
        this._listeners.get(type).push(handler);
    }
    removeEventListener(type, handler) {
        if (!this._listeners.has(type)) return;
        this._listeners.set(type, this._listeners.get(type).filter((h) => h !== handler));
    }
    // Test helper (not a real DOM API): synchronously invoke every listener
    // registered for `type` with a fake event object, returning that event
    // so the test can assert on preventDefault()/defaultPrevented.
    dispatch(type, evtOverrides) {
        const evt = Object.assign(
            {
                type,
                defaultPrevented: false,
                preventDefault() {
                    this.defaultPrevented = true;
                }
            },
            evtOverrides
        );
        const handlers = this._listeners.get(type) || [];
        handlers.forEach((h) => h(evt));
        return evt;
    }
    listenerCount(type) {
        return (this._listeners.get(type) || []).length;
    }
    appendChild(child) {
        this.children.push(child);
        return child;
    }
    querySelector() {
        // Not exercised by any code path these tests cover (the only
        // querySelector call in these files is gated behind
        // `session.theme_color && !isLcars`, which the LCARS-card tests
        // never hit).
        return null;
    }
}

function createDomStub() {
    const documentStub = {
        createElement(tag) {
            return new FakeElement(tag);
        },
        addEventListener() {
            // DOMContentLoaded etc. -- registered, never dispatched by
            // these tests, so a no-op is sufficient and correct.
        },
        getElementById() {
            return null;
        }
    };

    const windowOpenCalls = [];
    const ctx = {
        console,
        document: documentStub,
        // window === ctx, exactly like a real browser's global object,
        // so both bare `document`/`window` and `window.document` resolve
        // to the same stub inside the loaded script.
        window: null,
        open(url, target) {
            windowOpenCalls.push({ url, target });
        }
    };
    ctx.window = ctx;
    ctx.window.location = { origin: 'http://lcars-test.local' };
    ctx.window.open = ctx.open;
    ctx.window.addEventListener = function () {};

    return { ctx, document: documentStub, windowOpenCalls };
}

// XACA-0990-004: isLcarsTerminal()/createServiceOnlyLcarsCard() were
// extracted out of the 5 client app files into
// public/shared/js/lcars-terminal-card.js; each app file now delegates to
// the global LCARS_TERMINAL_CARD the real HTML pages load via a <script>
// tag ahead of the app.js tag (see the 5 lcars*.html pages). This vm.Context
// has no such tag-ordering, so without loading the shared module first, the
// patched client source below throws ReferenceError: LCARS_TERMINAL_CARD is
// not defined the moment its shim functions run. Load the real shared-module
// file (same "actual shipped source" rule as loadClientApp itself) into the
// SAME ctx, before the client app script, so it lands as a bare global the
// same way a browser's <script> tag would.
const SHARED_MODULE_REL_PATH = 'shared/js/lcars-terminal-card.js';

function loadSharedTerminalCardModule(ctx) {
    const filePath = path.join(PUBLIC_ROOT, SHARED_MODULE_REL_PATH);
    const src = fs.readFileSync(filePath, 'utf8');
    vm.runInContext(src, ctx, { filename: SHARED_MODULE_REL_PATH });

    if (!ctx.window || typeof ctx.window.LCARS_TERMINAL_CARD !== 'object') {
        throw new Error('lcars-client-dom-stub: LCARS_TERMINAL_CARD failed to load from ' + SHARED_MODULE_REL_PATH);
    }
}

// Loads one of the 5 client app IIFEs and returns whatever functions it
// stashed onto window.__lcarsTestExports. `relPath` is relative to
// fleet-monitor/server/public/ (e.g. 'lcars2/js/lcars-academy-app.js').
function loadClientApp(relPath, ctx) {
    const filePath = path.join(PUBLIC_ROOT, relPath);
    const src = fs.readFileSync(filePath, 'utf8');

    const marker = '})();';
    const lastIdx = src.lastIndexOf(marker);
    if (lastIdx === -1) {
        throw new Error('lcars-client-dom-stub: closing "})();" not found in ' + relPath);
    }

    const exportStmt =
        '\n    window.__lcarsTestExports = {' +
        ' escapeHtml: escapeHtml,' +
        ' createServiceOnlyLcarsCard: createServiceOnlyLcarsCard,' +
        ' createTeamCard: createTeamCard,' +
        ' isLcarsTerminal: isLcarsTerminal' +
        ' };\n';

    const patched = src.slice(0, lastIdx) + exportStmt + src.slice(lastIdx);

    vm.createContext(ctx);
    loadSharedTerminalCardModule(ctx);
    vm.runInContext(patched, ctx, { filename: relPath });

    const exports = ctx.window.__lcarsTestExports;
    if (!exports || typeof exports.createServiceOnlyLcarsCard !== 'function') {
        throw new Error('lcars-client-dom-stub: createServiceOnlyLcarsCard export missing from ' + relPath);
    }
    return exports;
}

// Exported (XACA-0990-005) so a test can load ONLY the shared module --
// e.g. to exercise LCARS_TERMINAL_CARD.createServiceOnlyLcarsCard's
// escapeHtml-must-be-a-function guard directly -- without needing to load
// one of the 5 client app shims on top of it. loadClientApp() above still
// calls this itself as step 1 of loading a client app.
module.exports = {
    createDomStub,
    loadClientApp,
    loadSharedTerminalCardModule,
    textContentToInnerHtml,
    FakeElement
};
