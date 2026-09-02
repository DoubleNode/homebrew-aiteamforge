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
    // XACA-1060: .remove()/.toggle() -- classList.add()/.contains() were the
    // only members previously exercised by any test through this stub;
    // updateMachineNavStats() (lcars-dashboard-app.js) is the first caller to
    // reach .toggle(force). Standard DOM semantics: toggle(cls) flips
    // membership; toggle(cls, force) sets membership to !!force.
    remove(cls) {
        const current = this._el.className ? this._el.className.split(/\s+/).filter(Boolean) : [];
        const next = current.filter((c) => c !== cls);
        this._el.className = next.join(' ');
    }
    toggle(cls, force) {
        const shouldHave = force === undefined ? !this.contains(cls) : !!force;
        if (shouldHave) this.add(cls); else this.remove(cls);
        return shouldHave;
    }
}

// XACA-0416: a CSSStyleDeclaration stand-in. The stub previously used a bare
// `{}`, which is enough for `el.style.display = 'none'` but silently lacks
// setProperty() -- so the theme_color path could not be RENDERED at all, only
// read. It models the three behaviours the theme_color assertions depend on:
//
//   * setProperty(name, value, priority) records the value AND its priority, so
//     a test can prove the `!important` survived the move off cssText.
//   * cssText is a real accessor pair, so a test can prove nothing wrote the
//     whole declaration block (the wide sink) behind its back.
//   * plain property assignment (`style.borderLeft = ...`) keeps working as an
//     own property, exactly as it did against the bare object.
//
// It is NOT a CSS parser: setting cssText does not populate individual
// properties, and setProperty does not validate the value. Both are out of
// scope -- these tests assert what the CLIENT CODE writes to the sink, not what
// a browser would then do with it.
class FakeStyle {
    constructor() {
        Object.defineProperty(this, '_props', { value: new Map(), enumerable: false, writable: true });
        Object.defineProperty(this, '_cssText', { value: '', enumerable: false, writable: true });
    }
    setProperty(name, value, priority) {
        this._props.set(String(name), { value: String(value), priority: priority || '' });
    }
    removeProperty(name) {
        this._props.delete(String(name));
    }
    getPropertyValue(name) {
        const entry = this._props.get(String(name));
        return entry ? entry.value : '';
    }
    getPropertyPriority(name) {
        const entry = this._props.get(String(name));
        return entry ? entry.priority : '';
    }
    get cssText() {
        return this._cssText;
    }
    set cssText(v) {
        this._cssText = String(v);
    }
}

// XACA-1060: dataset <-> data-* attribute reflection (camelCase <->
// kebab-case), same round-trip a real HTMLElement.dataset performs. Added
// for the MACHINES filter bar tests, which are the first callers to write
// `.dataset.foo = x` through this stub -- FakeElement previously had no
// `dataset` at all, so that write threw "Cannot set properties of
// undefined". Backed by the SAME `_attrs` Map setAttribute/getAttribute
// already use, so `el.dataset.machineHost = 'x'` and
// `el.getAttribute('data-machine-host')` agree, exactly like a real DOM.
function toKebabCase(name) {
    return String(name).replace(/[A-Z]/g, (c) => '-' + c.toLowerCase());
}
function toCamelCase(name) {
    return String(name).replace(/-([a-z0-9])/g, (_, c) => c.toUpperCase());
}
function createDatasetProxy(el) {
    return new Proxy({}, {
        get(_target, prop) {
            if (typeof prop !== 'string') return undefined;
            const attr = 'data-' + toKebabCase(prop);
            return el._attrs.has(attr) ? el._attrs.get(attr) : undefined;
        },
        set(_target, prop, value) {
            if (typeof prop === 'string') {
                el._attrs.set('data-' + toKebabCase(prop), String(value));
            }
            return true;
        },
        has(_target, prop) {
            return el._attrs.has('data-' + toKebabCase(String(prop)));
        },
        deleteProperty(_target, prop) {
            return el._attrs.delete('data-' + toKebabCase(String(prop)));
        },
        ownKeys() {
            const keys = [];
            for (const k of el._attrs.keys()) {
                if (k.indexOf('data-') === 0) keys.push(toCamelCase(k.slice(5)));
            }
            return keys;
        },
        getOwnPropertyDescriptor(_target, prop) {
            const attr = 'data-' + toKebabCase(String(prop));
            if (el._attrs.has(attr)) {
                return { enumerable: true, configurable: true, value: el._attrs.get(attr) };
            }
            return undefined;
        }
    });
}

// XACA-1060: a SMALL, deliberately non-general selector grammar -- just
// enough to support what applyMachineFilter()/renderMachineFilterNav() in
// lcars-dashboard-app.js actually pass: an optional tag (or `*`), zero or
// more `.class` tokens, and zero or more `[attr]` / `[attr="value"]`
// conditions, chained by AT MOST one descendant (space) or direct-child
// (`>`) combinator. This is not a CSS engine -- anything past that shape
// (attribute selectors with operators, `:not()`, sibling combinators,
// selector lists) is out of scope and will simply fail to match rather than
// silently do the wrong thing.
function parseCompoundSelector(str) {
    const m = /^([a-zA-Z][a-zA-Z0-9]*|\*)?((?:\.[A-Za-z0-9_-]+)*)((?:\[[^\]]+\])*)$/.exec(String(str || '').trim());
    if (!m) return null;
    const tag = m[1] || null;
    const classes = (m[2].match(/\.[A-Za-z0-9_-]+/g) || []).map((c) => c.slice(1));
    const attrs = (m[3].match(/\[[^\]]+\]/g) || []).map((a) => {
        const inner = a.slice(1, -1);
        const eq = inner.indexOf('=');
        if (eq === -1) return { name: inner.trim(), value: null };
        const name = inner.slice(0, eq).trim();
        const value = inner.slice(eq + 1).trim().replace(/^["']|["']$/g, '');
        return { name, value };
    });
    return { tag, classes, attrs };
}

function elementMatchesCompound(el, compound) {
    if (!compound) return false;
    if (compound.tag && compound.tag !== '*' && el.tagName !== compound.tag.toUpperCase()) return false;
    for (const cls of compound.classes) {
        if (!el.classList || !el.classList.contains(cls)) return false;
    }
    for (const attr of compound.attrs) {
        const has = el._attrs && el._attrs.has(attr.name);
        if (attr.value === null) {
            if (!has) return false;
        } else if (!has || el._attrs.get(attr.name) !== attr.value) {
            return false;
        }
    }
    return true;
}

// Parses "A" or "A B" (descendant) or "A > B" (direct child) into a list of
// {combinator, compound} steps. Bare-minimum: at most 2 steps, which is
// everything the client code passes today (e.g. '.chip-row > *[data-machine-host]').
function parseSelectorSteps(selector) {
    const childGroups = String(selector || '').split('>').map((s) => s.trim());
    const steps = [];
    childGroups.forEach((group, gi) => {
        group.split(/\s+/).filter(Boolean).forEach((part, pi) => {
            const combinator = pi > 0 ? 'descendant' : (gi > 0 ? 'child' : null);
            steps.push({ combinator, compound: parseCompoundSelector(part) });
        });
    });
    return steps;
}

// Real, tree-based (this.children, built by createElement()+appendChild())
// descendant search -- deliberately does NOT fall back to the innerHTML-string
// regex/synthesis FakeElement.querySelector() below relies on, so it only
// ever finds nodes that genuinely exist as objects in the tree. An element
// whose content was set via a raw `.innerHTML = "<span>...</span>"` template
// string (e.g. createDivisionPanel's division-header) has NO real children
// for its string-embedded markup, so this intentionally does not see inside
// it -- see the XACA-1060 test file for which assertions that rules out.
function collectDescendants(root, out) {
    (root.children || []).forEach((child) => {
        out.push(child);
        collectDescendants(child, out);
    });
    return out;
}

function deepQuerySelectorAll(root, selector) {
    const steps = parseSelectorSteps(selector);
    if (steps.length === 0 || steps.some((s) => !s.compound)) return [];

    let candidateSets = [collectDescendants(root, [])];
    steps.forEach((step, i) => {
        const prevMatches = i === 0 ? candidateSets[0] : candidateSets[candidateSets.length - 1];
        let next;
        if (i === 0) {
            next = prevMatches.filter((el) => elementMatchesCompound(el, step.compound));
        } else if (step.combinator === 'child') {
            // Direct children of each element that matched the PREVIOUS step.
            const parents = candidateSets[candidateSets.length - 1];
            next = [];
            parents.forEach((parent) => {
                (parent.children || []).forEach((child) => {
                    if (elementMatchesCompound(child, step.compound)) next.push(child);
                });
            });
        } else {
            // Descendant combinator (or a bare second token, treated the same).
            next = collectDescendants(root, []).filter((el) => elementMatchesCompound(el, step.compound));
        }
        candidateSets.push(next);
    });

    // De-duplicate while preserving order (a node can be reached via more
    // than one branch when the selector has multiple steps).
    const seen = new Set();
    const result = [];
    candidateSets[candidateSets.length - 1].forEach((el) => {
        if (!seen.has(el)) { seen.add(el); result.push(el); }
    });
    return result;
}

class FakeElement {
    constructor(tag) {
        this.tagName = String(tag || 'div').toUpperCase();
        this.className = '';
        this._innerHTML = '';
        this._attrs = new Map();
        this._listeners = new Map();
        this.style = new FakeStyle();
        this.title = '';
        this.classList = new FakeClassList(this);
        this.children = [];
        this._hidden = false;
        this.dataset = createDatasetProxy(this);
    }
    get id() {
        return this._attrs.has('id') ? this._attrs.get('id') : '';
    }
    set id(v) {
        this._attrs.set('id', String(v));
    }
    // XACA-1060: boolean IDL reflection of the `hidden` content attribute --
    // applyMachineFilter() sets `.hidden = true/false` directly (never
    // style.display, deliberately, per that function's own comments).
    get hidden() {
        return this._hidden;
    }
    set hidden(v) {
        this._hidden = !!v;
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
    // XACA-1060: real, tree-based querySelectorAll -- walks this.children
    // (populated by appendChild(), i.e. actual createElement()-built nodes),
    // NEVER the innerHTML-string regex/synthesis path querySelector() below
    // uses. Deliberately does not fall back to string-embedded content: a
    // selector that can only match markup baked into a raw `.innerHTML =`
    // template string (e.g. '.division-stats-count', nested inside
    // createDivisionPanel's division-header) returns an empty NodeList here,
    // same as it structurally must -- there is no such node anywhere in the
    // tree to find. See parseSelectorSteps/deepQuerySelectorAll above for the
    // (deliberately small) selector grammar this supports.
    querySelectorAll(selector) {
        return deepQuerySelectorAll(this, selector);
    }
    // XACA-0416-027 (PR #784 test gate) -- SECOND anti-vacuity note, about the
    // OTHER direction. The node returned below is SYNTHESISED and DETACHED: it
    // is not spliced into the innerHTML string this FakeElement holds, so a
    // style write on it never serializes back into `card.innerHTML`. A
    // legitimately-applied `#4A9EFF` is therefore absent from card.innerHTML by
    // construction.
    //
    // The tests written against this today are correct because they read
    // `style.getPropertyValue(...)` -- the live channel. But any FUTURE
    // assertion shaped "the payload is NOT in card.innerHTML" for the theme
    // sink would pass VACUOUSLY, whatever the sink does, and would look like
    // proof. Assert on the style object, or splice the node before asserting on
    // markup. Do not assert absence from innerHTML here.
    querySelector(selector) {
        // XACA-0416: the previous version returned null unconditionally, with a
        // note that no covered path reached it. That is no longer true -- the
        // theme_color guard's assertions render createTeamCard() with a
        // non-LCARS session, which takes the `card.querySelector('.team-name')`
        // branch, and a permanent null would have made those assertions pass
        // VACUOUSLY: the injection sink is inside `if (teamNameEl)`, so a null
        // means the sink is never reached and "no payload in the style block"
        // is true for the wrong reason.
        //
        // Deliberately minimal: ONE simple class selector, matched against the
        // element's innerHTML string. This stub does not parse HTML, so the
        // returned node is synthesised rather than found -- which is exactly
        // what these tests need (a fresh element carrying an empty style
        // declaration block, which is what a browser hands back here too). It
        // is cached per class so repeated queries return the SAME node, as a
        // real DOM would; without that, a test reading the style back would
        // read it off a different element than the one the client code wrote.
        // Anything more complex than `.class` returns null rather than guessing.
        const m = /^\.([A-Za-z][A-Za-z0-9_-]*)$/.exec(String(selector || ''));
        if (!m) return null;
        const cls = m[1];
        // XACA-1060: check REAL children (this.children, appendChild()-built)
        // FIRST, depth-first -- if a genuine node with this class exists in
        // the tree, return that live node instead of a synthesised, detached
        // one. This is backward compatible by construction: every existing
        // caller of querySelector() targets an element whose matching content
        // was set via a raw innerHTML STRING (createTeamCard,
        // createServiceOnlyLcarsCard, ...), which appendChild() never
        // populated, so `this.children` is empty for those and this check
        // always misses, falling through to the untouched regex/synthesis
        // path below exactly as before XACA-1060.
        const realMatches = deepQuerySelectorAll(this, '.' + cls);
        if (realMatches.length > 0) return realMatches[0];
        // Token membership, not a substring match: `.team` must not match
        // class="team-card". Pull every class attribute out of the markup and
        // split each on whitespace, the same tokenisation the HTML spec uses.
        const classAttrs = String(this._innerHTML || '').match(/class="[^"]*"/g) || [];
        const present = classAttrs.some(function (attr) {
            return attr.slice('class="'.length, -1).split(/\s+/).indexOf(cls) !== -1;
        });
        if (!present) return null;
        if (!this._querySelectorCache) this._querySelectorCache = new Map();
        if (!this._querySelectorCache.has(cls)) {
            const el = new FakeElement('div');
            el.className = cls;
            this._querySelectorCache.set(cls, el);
        }
        return this._querySelectorCache.get(cls);
    }
}

// XACA-0416 (review finding: safeCssIdent validates syntax, not token existence).
//
// The client's cssTokenIsDefined() asks the DOM whether `--lcars-<ident>`
// resolves to anything. To render that decision honestly this stub needs a
// getComputedStyle backed by the tokens the REAL page defines -- not a
// hand-written table, which would let the test agree with itself while the
// shipped stylesheets said something else.
//
// So: read the page's own <link rel="stylesheet"> list, resolve each href
// relative to the HTML file, and collect every `--name: value` definition. Same
// "actual shipped source" rule loadClientApp() follows for the JS.
//
// OPT-IN. Without `cssVarsFromPage`, getComputedStyle is ABSENT from the
// context, exactly as before -- so every pre-existing test keeps rendering
// against the same stub surface it was written for, and the client's
// fail-safe-to-current-behaviour branch is what those tests exercise.
function collectCssCustomProperties(pageRelPath) {
    const pagePath = path.join(PUBLIC_ROOT, pageRelPath);
    const html = fs.readFileSync(pagePath, 'utf8');
    const pageDir = path.dirname(pagePath);

    const hrefs = [];
    const linkRe = /<link\b[^>]*rel=["']stylesheet["'][^>]*>/gi;
    let m;
    while ((m = linkRe.exec(html)) !== null) {
        const hrefMatch = /href=["']([^"']+)["']/i.exec(m[0]);
        if (!hrefMatch) continue;
        const href = hrefMatch[1].split('?')[0];
        // Remote sheets (the Google Fonts import) cannot define --lcars-*
        // tokens and are not on disk to read. Skipped rather than fetched --
        // a unit test must not depend on the network.
        if (/^(https?:)?\/\//i.test(href)) continue;
        hrefs.push(href);
    }
    if (hrefs.length === 0) {
        throw new Error('lcars-client-dom-stub: no local stylesheets found in ' + pageRelPath);
    }

    const vars = new Map();
    hrefs.forEach(function (href) {
        const cssPath = path.resolve(pageDir, href);
        if (!fs.existsSync(cssPath)) {
            throw new Error('lcars-client-dom-stub: stylesheet missing on disk: ' + cssPath);
        }
        const css = fs.readFileSync(cssPath, 'utf8');
        const declRe = /(--[A-Za-z0-9_-]+)\s*:\s*([^;}]+)/g;
        let d;
        while ((d = declRe.exec(css)) !== null) {
            vars.set(d[1], d[2].trim());
        }
    });
    return vars;
}

function createDomStub(options) {
    const opts = options || {};
    // XACA-1060: id -> element registry, opt-in only. A real document finds
    // an element by id because it is somewhere in the live tree; this stub
    // has no such tree root to search (createElement() builds detached nodes
    // until a test's own code appendChild()s them together), so a test that
    // needs getElementById('foo') to resolve registers that specific element
    // explicitly via document.__registerById('foo', el) BEFORE calling into
    // client code. Every existing test that never calls __registerById sees
    // getElementById() return null exactly as before this change.
    const byId = new Map();
    const documentStub = {
        createElement(tag) {
            return new FakeElement(tag);
        },
        addEventListener() {
            // DOMContentLoaded etc. -- registered, never dispatched by
            // these tests, so a no-op is sufficient and correct.
        },
        getElementById(id) {
            return byId.has(id) ? byId.get(id) : null;
        },
        __registerById(id, el) {
            byId.set(id, el);
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

    let cssVars = null;
    if (opts.cssVarsFromPage) {
        cssVars = collectCssCustomProperties(opts.cssVarsFromPage);
        documentStub.documentElement = new FakeElement('html');
        const computed = {
            // A real getComputedStyle returns '' for a custom property that is
            // not defined anywhere in the cascade -- that '' is the entire
            // signal cssTokenIsDefined() reads.
            getPropertyValue(name) {
                const key = String(name);
                return cssVars.has(key) ? cssVars.get(key) : '';
            }
        };
        ctx.getComputedStyle = function () {
            return computed;
        };
        ctx.window.getComputedStyle = ctx.getComputedStyle;
    }

    return { ctx, document: documentStub, windowOpenCalls, cssVars };
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

    // XACA-0416 adds `setWorkingItems`. The working-item row createTeamCard()
    // renders is gated on the IIFE-scoped `workingItems` cache, which is only
    // ever populated by a fetch inside the DOMContentLoaded handler this loader
    // never dispatches -- so without a setter, the truncation path is
    // unreachable from a test and could only be READ, not rendered. It is
    // `typeof`-guarded because only lcars-dashboard-app.js declares that
    // variable; in the four lcars2 files the export lands as null rather than
    // throwing a ReferenceError at load.
    const exportStmt =
        '\n    window.__lcarsTestExports = {' +
        ' escapeHtml: escapeHtml,' +
        ' createServiceOnlyLcarsCard: createServiceOnlyLcarsCard,' +
        ' createTeamCard: createTeamCard,' +
        ' isLcarsTerminal: isLcarsTerminal,' +
        ' setWorkingItems: (typeof workingItems !== "undefined")' +
        '     ? function (v) { workingItems = v; } : null,' +
        // XACA-0416 (review finding: safeCssIdent validates syntax, not token
        // existence). dashboardLinkStyle() is the sidebar-link CSS sink; only
        // lcars-dashboard-app.js defines it, so it is typeof-guarded for the
        // same reason setWorkingItems is -- in the four lcars2 files the export
        // lands as null rather than throwing a ReferenceError at load.
        ' dashboardLinkStyle: (typeof dashboardLinkStyle !== "undefined")' +
        '     ? dashboardLinkStyle : null,' +
        // XACA-1060: MACHINES filter bar (subitems 004-006) -- only
        // lcars-dashboard-app.js defines these, hence typeof-guarded like
        // the two exports above. setCachedMachineData lets a test populate
        // the module-scope cachedMachineData cache renderMachineFilterNav()
        // reads, without needing to run the fetch-driven renderDashboard().
        ' renderDivisions: (typeof renderDivisions !== "undefined")' +
        '     ? renderDivisions : null,' +
        ' applyMachineFilter: (typeof applyMachineFilter !== "undefined")' +
        '     ? applyMachineFilter : null,' +
        ' toggleMachineFilter: (typeof toggleMachineFilter !== "undefined")' +
        '     ? toggleMachineFilter : null,' +
        ' renderMachineFilterNav: (typeof renderMachineFilterNav !== "undefined")' +
        '     ? renderMachineFilterNav : null,' +
        ' updateMachineNavStats: (typeof updateMachineNavStats !== "undefined")' +
        '     ? updateMachineNavStats : null,' +
        ' setCachedMachineData: (typeof cachedMachineData !== "undefined")' +
        '     ? function (v) { cachedMachineData = v; } : null,' +
        // setTeamConfig/setDivisionToTeamMap: createDivisionAvatarGrid's
        // avatar lookup (getTeamAvatarUrl) is gated on both of these
        // module-scope caches, normally populated by a fetch this loader
        // never dispatches -- without a setter the avatar-grid path is
        // unreachable from a test, same rationale as setWorkingItems above.
        ' setTeamConfig: (typeof teamConfig !== "undefined")' +
        '     ? function (v) { teamConfig = v; } : null,' +
        ' setDivisionToTeamMap: (typeof divisionToTeamMap !== "undefined")' +
        '     ? function (v) { divisionToTeamMap = v; } : null' +
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
    collectCssCustomProperties,
    createDomStub,
    loadClientApp,
    loadSharedTerminalCardModule,
    textContentToInnerHtml,
    FakeElement,
    FakeStyle
};
