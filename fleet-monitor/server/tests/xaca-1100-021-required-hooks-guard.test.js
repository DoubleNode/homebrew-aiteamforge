//
//  xaca-1100-021-required-hooks-guard.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1100-021 [Review] -- the required-hooks guard
 * `LCARS.machines.createMachineItem()` grew in the PR #826 first review
 * round (XACA-1100-014, see that block comment in
 * fleet-monitor/server/public/lcars2/js/lcars-fleet-core.js) had ZERO test
 * coverage of its own. The guard replaced a silent `deps = deps || {}`
 * fallback with a loud `throw` naming the missing key(s) -- this file
 * proves that throw actually fires with the right message in every shape
 * the guard is supposed to catch, and (just as importantly) proves it does
 * NOT fire for the one legitimately-optional key.
 *
 * This is a documentation-of-existing-behavior suite, not a
 * behavior-change suite -- the PR #826 second review round manually
 * verified all of the assertions below hold in jsdom already. If any one
 * of them does NOT hold when this file is run, that means the guard itself
 * is wrong, not this test -- see the ticket brief.
 *
 * ── Route taken ───────────────────────────────────────────────────────────
 * This targets `LCARS.machines.createMachineItem()` directly, the one
 * function that owns the guard -- not a full lcars2 app file's
 * `renderMachines()` call site (XACA-1100-013 already owns that
 * end-to-end wiring test). tests/helpers/lcars-client-dom-stub.js's
 * `createDomStub()` + `loadFleetCoreModule()` gives exactly enough of a
 * hand-rolled `document`/`window` for `lcars-fleet-core.js` to load and run
 * -- the same stub every other guard/adapter-level suite in this directory
 * (xaca-1092-006, xaca-1031-*) already relies on. No jsdom needed: the
 * guard itself never touches the DOM (it runs before `machine.system` is
 * even read), and the one positive-case render below only exercises the
 * `buildSystemSectionHtml() -> ''` branch, which needs nothing more than
 * `document.createElement`/`createDocumentFragment` -- both of which the
 * hand stub provides.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { createDomStub, loadFleetCoreModule } = require('./helpers/lcars-client-dom-stub.js');

// Mirrors the real REQUIRED_DEPS array in
// fleet-monitor/server/public/lcars2/js/lcars-fleet-core.js's
// createMachineItem() -- order matters: the guard's error message lists
// missing keys in THIS order, so the "all missing" assertions below are
// exact-string, not substring, checks.
const REQUIRED_DEPS = ['machineSystemToHealthInput', 'healthBadgeSpec', 'buildSystemSectionHtml', 'toggleSystemPanel'];

function guardMessage(missingKeys) {
    return 'LCARS.machines.createMachineItem: deps.' + missingKeys.join('(), deps.') +
        '() must be supplied as function(s) -- see the deps JSDoc on this method.';
}

// Loads the real shipped lcars-fleet-core.js into a fresh hand-rolled DOM
// stub and returns the LCARS_CORE.machines namespace it produces.
function loadMachinesCore() {
    const { ctx } = createDomStub();
    vm.createContext(ctx);
    loadFleetCoreModule(ctx);
    return ctx.window.LCARS_CORE.machines;
}

// A complete set of valid (no-op) hook functions -- every required key
// present and callable. `overrides` lets a test knock out or corrupt one
// key at a time without retyping the other three.
function validDeps(overrides) {
    return Object.assign({
        machineSystemToHealthInput: function (system) { return system; },
        healthBadgeSpec: function () { return null; },
        buildSystemSectionHtml: function () { return ''; },
        toggleSystemPanel: function () {}
    }, overrides);
}

// The minimal machine object createMachineItem() reads unconditionally on
// the success path, with buildSystemSectionHtml() stubbed to return ''
// (the "no SYSTEM data" branch) so machine_id / toggleSystemPanel wiring is
// never reached -- irrelevant to what this file is testing (the deps
// guard), so kept out of the fixture entirely.
function minimalMachine() {
    return {
        machine_id: 'xaca-1100-021-fixture-machine',
        hostname: 'xaca-1100-021.example.test',
        status: 'online',
        session_count: 0,
        system: {}
    };
}

// ============================================================================
// deps undefined / deps empty -- throws naming ALL FOUR missing keys
// ============================================================================

test('XACA-1100-021: createMachineItem() with deps undefined throws, naming all 4 required keys', () => {
    const machines = loadMachinesCore();
    assert.throws(
        () => machines.createMachineItem(minimalMachine(), undefined),
        (err) => err && err.message === guardMessage(REQUIRED_DEPS),
        'expected the exact all-4-keys guard message when deps is undefined'
    );
});

test('XACA-1100-021: createMachineItem() with deps omitted entirely (called with one argument) throws, naming all 4 required keys', () => {
    const machines = loadMachinesCore();
    assert.throws(
        () => machines.createMachineItem(minimalMachine()),
        (err) => err && err.message === guardMessage(REQUIRED_DEPS),
        'expected the exact all-4-keys guard message when deps is not passed at all'
    );
});

test('XACA-1100-021: createMachineItem() with deps = {} throws, naming all 4 required keys', () => {
    const machines = loadMachinesCore();
    assert.throws(
        () => machines.createMachineItem(minimalMachine(), {}),
        (err) => err && err.message === guardMessage(REQUIRED_DEPS),
        'expected the exact all-4-keys guard message when deps is an empty object'
    );
});

// ============================================================================
// Exactly one hook missing -- throws naming ONLY that key
// ============================================================================

REQUIRED_DEPS.forEach((missingKey) => {
    test(`XACA-1100-021: createMachineItem() missing ONLY deps.${missingKey} throws naming ONLY that key`, () => {
        const machines = loadMachinesCore();
        const deps = validDeps();
        delete deps[missingKey];

        assert.throws(
            () => machines.createMachineItem(minimalMachine(), deps),
            (err) => err && err.message === guardMessage([missingKey]),
            'expected the guard message to name exactly one missing key (' + missingKey + ') and no others'
        );
    });
});

// ============================================================================
// A hook present but not a function (wrong type) -- throws
// ============================================================================

REQUIRED_DEPS.forEach((wrongTypeKey) => {
    test(`XACA-1100-021: createMachineItem() with deps.${wrongTypeKey} present but NOT a function throws naming that key`, () => {
        const machines = loadMachinesCore();
        // A present-but-wrong-type value must be treated identically to an
        // absent one -- the guard checks `typeof deps[key] !== 'function'`,
        // not `key in deps` / truthiness, specifically so a caller who wires
        // in a string, object, or stale non-function reference gets the same
        // loud, named failure as a caller who forgot the key outright.
        const deps = validDeps({ [wrongTypeKey]: 'not-a-function' });

        assert.throws(
            () => machines.createMachineItem(minimalMachine(), deps),
            (err) => err && err.message === guardMessage([wrongTypeKey]),
            'expected a present-but-wrong-type hook to be reported exactly like a missing one'
        );
    });
});

// ============================================================================
// POSITIVE: omitting ONLY isSystemExpanded (the sole legitimately-optional
// key) must NOT throw.
// ============================================================================

test('XACA-1100-021: createMachineItem() with all 4 required hooks present and isSystemExpanded OMITTED does NOT throw', () => {
    const machines = loadMachinesCore();
    const deps = validDeps(); // deliberately no isSystemExpanded key at all

    let fragment;
    assert.doesNotThrow(() => {
        fragment = machines.createMachineItem(minimalMachine(), deps);
    }, 'isSystemExpanded is the one optional key (coerced with `!!` in the source) -- its absence must never trip the required-hooks guard');

    assert.ok(fragment, 'createMachineItem() must still return a real fragment on the positive path');
});

test('XACA-1100-021: createMachineItem() with all 4 required hooks present and isSystemExpanded explicitly false also does NOT throw (sanity control for the omitted-key case above)', () => {
    const machines = loadMachinesCore();
    const deps = validDeps({ isSystemExpanded: false });

    assert.doesNotThrow(() => {
        machines.createMachineItem(minimalMachine(), deps);
    });
});
