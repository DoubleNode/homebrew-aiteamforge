//
//  xaca-1154-008-kiosk-toggle-markup-binding-jsdom.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';
/**
 * XACA-1154 subitem 008 -- executes the REAL production markup + REAL
 * dashboard-app.js binding + REAL lcars-kiosk.js module together in jsdom.
 *
 * This closes the one seam left untested after subitem 006: subitem 006's
 * coverage of the two dashboard app.js call sites (see
 * tests/xaca-1154-006-kiosk-enable-exit-movement-jsdom.test.js, test group
 * "(b) call-site defense-in-depth") is a SOURCE-REGEX characterization,
 * never actual execution -- its own comment explains why: these files
 * register a DOMContentLoaded handler that fetches from a nonexistent host
 * plus unbounded setInterval timers, and executing them carelessly hangs
 * `node --test` indefinitely (see tests/xaca-1060-008-machine-filter-jsdom
 * .test.js, which documents and works around the same hazard). Subitem 006
 * therefore never actually ran the #kiosk-mode-toggle binding code against
 * a real DOM -- nobody had, until this file. Two dashboards are exercised,
 * matching the subitem-008 task brief's designated representatives:
 *
 *   - lcars/lcars-dashboard.html + lcars/js/lcars-dashboard-app.js
 *     (the lcars v1 case; also the only one with the #kiosk-enter-btn FAB)
 *   - lcars2/lcars-index.html + lcars2/js/lcars-fleet-dashboard-app.js
 *     + lcars2/js/lcars-academy-config.js
 *     (the lcars2 case; the real per-org config script that a real page
 *     load would fetch first is loaded here too, for fidelity)
 *
 * Hang-avoidance (proven safe, not assumed): window.setInterval is
 * replaced with a no-op BEFORE either script is eval'd, so the three
 * timers app.js schedules (fleet-data refresh, stardate ticker, lcars-
 * dashboard-app.js's additional "Last:" timer) never become real Node
 * timers -- window.setTimeout is untouched (the kiosk module's own idle/
 * exit-handler timers depend on it and are torn down explicitly via
 * K.destroy() in every test's `finally`). window.fetch is replaced with a
 * mock that resolves immediately with a body shaped enough to satisfy
 * every consumer this handler reaches (dashboard config, team config,
 * fleet data) without throwing, so every `await` in the handler settles
 * within a tick instead of hitting a real network.
 *
 * What is proven, per the toggle element, using the REAL markup + REAL
 * binding (never a direct LCARS_KIOSK API call standing in for the DOM
 * event a user actually produces):
 *   - it exists, is a real <input type="checkbox">, id="kiosk-mode-toggle"
 *   - .checked on load reflects LCARS_KIOSK.isEnabled(), including the
 *     stored-'false' case (the classic Boolean("false")===true trap)
 *   - a real 'change' event with checked=false actually reaches
 *     LCARS_KIOSK.setEnabled(false) -- proven BEHAVIOURALLY (idle
 *     monitoring genuinely stops: kiosk does not auto-activate after the
 *     idle timeout elapses), not merely by reading isEnabled() back
 *   - flipping back to checked=true re-arms idle monitoring the same way
 *   - <label for="kiosk-mode-toggle"> is a REAL label/control association
 *     (HTMLLabelElement.control, the browser-computed association -- not
 *     mere DOM proximity), and the control is keyboard-reachable (no
 *     negative tabindex, not disabled) -- this ticket is about a UI a
 *     user cannot otherwise dismiss, so a mouse-only off switch would be
 *     its own joke.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const PUBLIC_ROOT = path.join(__dirname, '..', 'public');
const KIOSK_SRC = fs.readFileSync(path.join(PUBLIC_ROOT, 'shared/js/lcars-kiosk.js'), 'utf8');
const STORAGE_KEY = 'lcars-kiosk-enabled';

const DASHBOARDS = [
    {
        label: 'lcars/lcars-dashboard.html',
        html: path.join(PUBLIC_ROOT, 'lcars/lcars-dashboard.html'),
        configJs: null,
        appJs: path.join(PUBLIC_ROOT, 'lcars/js/lcars-dashboard-app.js'),
    },
    {
        label: 'lcars2/lcars-index.html',
        html: path.join(PUBLIC_ROOT, 'lcars2/lcars-index.html'),
        configJs: path.join(PUBLIC_ROOT, 'lcars2/js/lcars-academy-config.js'),
        appJs: path.join(PUBLIC_ROOT, 'lcars2/js/lcars-fleet-dashboard-app.js'),
    },
    // XACA-1154 (test gate, PR #851 round 3): the remaining three production
    // dashboards.
    //
    // This file previously covered 2 of the 5 dashboards that carry the toggle.
    // The other three were verified BY HAND during the round-2 gate — identical
    // markup, correct `label for=`, both scripts loaded — and that is precisely
    // the problem: the markup is duplicated five times with no shared include,
    // so it is free to drift silently and a hand check expires the moment
    // someone edits one file. A per-dashboard entry here costs nothing (every
    // test below is already written as a loop over this array) and converts a
    // one-time manual observation into a standing assertion.
    //
    // These three differ from lcars-index only in their per-org config script,
    // which sets window.LCARS_DASHBOARD_CONFIG; they share the same app JS.
    {
        label: 'lcars2/lcars-all.html',
        html: path.join(PUBLIC_ROOT, 'lcars2/lcars-all.html'),
        configJs: path.join(PUBLIC_ROOT, 'lcars2/js/lcars-all-config.js'),
        appJs: path.join(PUBLIC_ROOT, 'lcars2/js/lcars-fleet-dashboard-app.js'),
    },
    {
        label: 'lcars2/lcars-doublenode.html',
        html: path.join(PUBLIC_ROOT, 'lcars2/lcars-doublenode.html'),
        configJs: path.join(PUBLIC_ROOT, 'lcars2/js/lcars-doublenode-config.js'),
        appJs: path.join(PUBLIC_ROOT, 'lcars2/js/lcars-fleet-dashboard-app.js'),
    },
    {
        label: 'lcars2/lcars-mainevent.html',
        html: path.join(PUBLIC_ROOT, 'lcars2/lcars-mainevent.html'),
        configJs: path.join(PUBLIC_ROOT, 'lcars2/js/lcars-mainevent-config.js'),
        appJs: path.join(PUBLIC_ROOT, 'lcars2/js/lcars-fleet-dashboard-app.js'),
    },
];

// Guard against this array silently falling out of step with the product.
// If a sixth dashboard gains the toggle (or one loses it), this fails loudly
// rather than leaving the new file uncovered the way three were before.
test('[coverage] every production dashboard carrying #kiosk-mode-toggle is represented in DASHBOARDS', () => {
    const candidates = [];
    for (const dir of ['lcars', 'lcars2']) {
        const abs = path.join(PUBLIC_ROOT, dir);
        for (const name of fs.readdirSync(abs)) {
            if (!name.endsWith('.html')) continue;
            // lcars-test.html x2 are deliberately excluded from this feature.
            if (name.includes('lcars-test')) continue;
            const html = fs.readFileSync(path.join(abs, name), 'utf8');
            if (html.includes('id="kiosk-mode-toggle"')) candidates.push(`${dir}/${name}`);
        }
    }
    const covered = DASHBOARDS.map((d) => d.label).sort();
    assert.deepEqual(
        candidates.sort(),
        covered,
        'every dashboard shipping the kiosk toggle must have a DASHBOARDS entry'
    );
    assert.equal(covered.length, 5, 'expected exactly 5 production dashboards');
});

function wait(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

// One fake body shaped to satisfy every JSON consumer this handler chain
// reaches (dashboard config's config.name.toUpperCase() call sites, team
// config's Object.keys(teamConfig.teams), fleet data's array/object
// expectations) so a mocked-but-successful fetch never itself throws and
// masks what this file is actually testing.
function fakeFetchResponse() {
    const body = {
        name: 'Test',
        title: 'Test',
        subtitle: 'Test',
        org_color: 'lavender',
        divisions: [],
        machines: [],
        teams: {},
    };
    return Promise.resolve({
        ok: true,
        status: 200,
        statusText: 'OK',
        json: () => Promise.resolve(body),
    });
}

// Loads the REAL html file's document (via jsdom's own HTML parser, not a
// synthetic string) and evals the REAL kiosk.js (+ config.js, when the
// dashboard has one) + REAL app.js sources into it, in the same order the
// browser would load them via <script src> before DOMContentLoaded fires.
function loadDashboard(spec) {
    const htmlSrc = fs.readFileSync(spec.html, 'utf8');
    const dom = new JSDOM(htmlSrc, { runScripts: 'outside-only', url: 'https://lcars-test.local/' });
    const window = dom.window;
    const document = window.document;

    // Real setInterval would keep `node --test` alive forever (refreshTimer,
    // stardate ticker, and -- lcars/js/lcars-dashboard-app.js only -- the
    // "Last:" timer). Neutralise before any script runs. setTimeout is left
    // real: the kiosk module's idle/exit timers need it, and every test
    // tears its instance down with K.destroy() in `finally`.
    window.setInterval = function () { return 0; };
    window.fetch = function () { return fakeFetchResponse(); };

    window.eval(KIOSK_SRC);
    if (!window.LCARS_KIOSK) {
        throw new Error(spec.label + ': window.LCARS_KIOSK did not attach after eval');
    }

    if (spec.configJs) {
        // Script tag order matters for this file (D5/D6, XACA-1110): the
        // per-org config script sets window.LCARS_DASHBOARD_CONFIG, which
        // app.js reads once at module-eval time -- it must run first.
        window.eval(fs.readFileSync(spec.configJs, 'utf8'));
    }

    window.eval(fs.readFileSync(spec.appJs, 'utf8'));

    return { dom, window, document, K: window.LCARS_KIOSK };
}

// LCARS_KIOSK.destroy() clears any idle/exit timers the boot below may
// have armed; window.close() releases the jsdom instance. Both are best
// effort so a failed assertion above still tears down cleanly.
function teardown(instance) {
    try { instance.K.destroy(); } catch (e) { /* best effort */ }
    try { instance.window.close(); } catch (e) { /* best effort */ }
}

// Fires DOMContentLoaded and waits long enough for the handler's async
// chain to reach and pass the kiosk toggle binding (including, for
// lcars/lcars-dashboard-app.js, the awaited loadDashboardConfig() fetch
// mocked above, which sits BEFORE the kiosk section in that file).
async function boot(instance) {
    instance.document.dispatchEvent(new instance.window.Event('DOMContentLoaded', { bubbles: true, cancelable: true }));
    await wait(50);
}

function setStoredPreference(window, value) {
    if (value === undefined) {
        window.localStorage.removeItem(STORAGE_KEY);
    } else {
        window.localStorage.setItem(STORAGE_KEY, value);
    }
}

function getToggle(document) {
    return document.getElementById('kiosk-mode-toggle');
}

// ============================================================================
// Per-dashboard seam tests
// ============================================================================

for (const spec of DASHBOARDS) {

    test(`[${spec.label}] toggle exists in the real rendered document, is a real checkbox, reachable by id`, async () => {
        const inst = loadDashboard(spec);
        try {
            await boot(inst);
            const toggle = getToggle(inst.document);
            assert.ok(toggle, 'kiosk-mode-toggle element must exist');
            assert.equal(toggle.tagName, 'INPUT', 'must be a real <input>, not a div/span widget');
            assert.equal(toggle.type, 'checkbox', 'must be type="checkbox"');
        } finally { teardown(inst); }
    });

    test(`[${spec.label}] on load, checked reflects isEnabled() when the stored preference is 'false'`, async () => {
        const inst = loadDashboard(spec);
        try {
            setStoredPreference(inst.window, 'false');
            await boot(inst);
            const toggle = getToggle(inst.document);
            assert.equal(inst.K.isEnabled(), false, 'setup: isEnabled() must read the stored false');
            assert.equal(toggle.checked, false, "checkbox must start UNchecked when the stored preference is 'false' -- the exact case a truthy-string-coercion bug gets backwards");
        } finally { teardown(inst); }
    });

    test(`[${spec.label}] on load, checked reflects isEnabled() when the stored preference is 'true'`, async () => {
        const inst = loadDashboard(spec);
        try {
            setStoredPreference(inst.window, 'true');
            await boot(inst);
            const toggle = getToggle(inst.document);
            assert.equal(inst.K.isEnabled(), true);
            assert.equal(toggle.checked, true, "checkbox must start checked when the stored preference is 'true'");
        } finally { teardown(inst); }
    });

    test(`[${spec.label}] on load, checked reflects the default when nothing is stored`, async () => {
        const inst = loadDashboard(spec);
        try {
            setStoredPreference(inst.window, undefined);
            await boot(inst);
            const toggle = getToggle(inst.document);
            assert.equal(toggle.checked, inst.K.isEnabled(), 'checkbox must match isEnabled() default when nothing is stored');
        } finally { teardown(inst); }
    });

    test(`[${spec.label}] a real 'change' event to unchecked reaches setEnabled(false) and genuinely stops idle monitoring`, async () => {
        const inst = loadDashboard(spec);
        try {
            setStoredPreference(inst.window, 'true');
            inst.K.config.idleTimeout = 30;
            await boot(inst);

            const toggle = getToggle(inst.document);
            assert.equal(toggle.checked, true, 'setup: starts checked/enabled');

            // Prove idle monitoring is genuinely running from the real
            // init() call the binding made -- OBSERVED, not asserted: wait
            // past the (now tiny) idle timeout and confirm kiosk actually
            // auto-activates on its own.
            await wait(80);
            assert.equal(inst.K.isActive(), true, 'setup: idle monitoring must have auto-activated kiosk -- if this fails, the rest of this test proves nothing');

            // Flip the REAL checkbox and dispatch a REAL 'change' event --
            // exactly what a user click produces -- and let the app.js
            // binding's own listener (not a direct API call) do the work.
            toggle.checked = false;
            toggle.dispatchEvent(new inst.window.Event('change', { bubbles: true }));

            assert.equal(inst.K.isEnabled(), false, 'the change event must have reached LCARS_KIOSK.setEnabled(false)');
            assert.equal(inst.K.isActive(), false, 'setEnabled(false) must exit the currently-active kiosk');

            // The regression this subitem exists to guard: does idle
            // monitoring stay OFF, or does something resurrect it? Wait
            // well past the (still-30ms) idle timeout again.
            await wait(80);
            assert.equal(inst.K.isActive(), false, 'idle monitoring must NOT have restarted -- kiosk must not resurrect after being turned off via the real toggle');
        } finally { teardown(inst); }
    });

    test(`[${spec.label}] a real 'change' event back to checked re-arms idle monitoring`, async () => {
        const inst = loadDashboard(spec);
        try {
            setStoredPreference(inst.window, 'false');
            inst.K.config.idleTimeout = 30;
            await boot(inst);

            const toggle = getToggle(inst.document);
            assert.equal(toggle.checked, false, 'setup: starts unchecked/disabled');
            await wait(80);
            assert.equal(inst.K.isActive(), false, 'setup: kiosk must stay inactive while disabled');

            toggle.checked = true;
            toggle.dispatchEvent(new inst.window.Event('change', { bubbles: true }));
            assert.equal(inst.K.isEnabled(), true, 'the change event must have reached setEnabled(true)');

            await wait(80);
            assert.equal(inst.K.isActive(), true, 'idle monitoring must have (re)started and auto-activated kiosk after the real toggle turned it back on');
        } finally { teardown(inst); }
    });

    // XACA-1154-019: cross-tab sync. A same-window localStorage write never
    // fires a 'storage' event locally -- only the event itself is simulated
    // here, exactly like the browser delivering another tab's write TO this
    // tab (the write to inst.window.localStorage mirrors what that other
    // tab's own write would have already left behind in the shared store).
    test(`[${spec.label}] a real 'storage' event to 'false' unchecks the REAL checkbox and genuinely stops idle monitoring (cross-tab sync)`, async () => {
        const inst = loadDashboard(spec);
        try {
            setStoredPreference(inst.window, 'true');
            inst.K.config.idleTimeout = 30;
            await boot(inst);

            const toggle = getToggle(inst.document);
            assert.equal(toggle.checked, true, 'setup: starts checked/enabled');
            await wait(80);
            assert.equal(inst.K.isActive(), true, 'setup: idle monitoring must have auto-activated kiosk -- if this fails, the rest of this test proves nothing');

            inst.window.localStorage.setItem(STORAGE_KEY, 'false');
            inst.window.dispatchEvent(new inst.window.StorageEvent('storage', {
                key: STORAGE_KEY, newValue: 'false', storageArea: inst.window.localStorage,
            }));

            assert.equal(toggle.checked, false, 'the REAL checkbox must reflect the cross-tab change');
            assert.equal(inst.K.isActive(), false, 'kiosk must exit on the cross-tab disable');

            await wait(80);
            assert.equal(inst.K.isActive(), false, 'idle monitoring must NOT have resurrected after the cross-tab disable');
        } finally { teardown(inst); }
    });

    test(`[${spec.label}] a real 'storage' event to 'true' checks the REAL checkbox and genuinely re-arms idle monitoring (cross-tab sync)`, async () => {
        const inst = loadDashboard(spec);
        try {
            setStoredPreference(inst.window, 'false');
            inst.K.config.idleTimeout = 30;
            await boot(inst);

            const toggle = getToggle(inst.document);
            assert.equal(toggle.checked, false, 'setup: starts unchecked/disabled');
            await wait(80);
            assert.equal(inst.K.isActive(), false, 'setup: kiosk must stay inactive while disabled');

            inst.window.localStorage.setItem(STORAGE_KEY, 'true');
            inst.window.dispatchEvent(new inst.window.StorageEvent('storage', {
                key: STORAGE_KEY, newValue: 'true', storageArea: inst.window.localStorage,
            }));

            assert.equal(toggle.checked, true, 'the REAL checkbox must reflect the cross-tab change');

            await wait(80);
            assert.equal(inst.K.isActive(), true, 'idle monitoring must have (re)armed and auto-activated kiosk after the cross-tab enable');
        } finally { teardown(inst); }
    });

    test(`[${spec.label}] label/control association is real, and the control is keyboard-reachable`, async () => {
        const inst = loadDashboard(spec);
        try {
            await boot(inst);
            const toggle = getToggle(inst.document);
            const label = inst.document.querySelector('label[for="kiosk-mode-toggle"]');
            assert.ok(label, 'a <label for="kiosk-mode-toggle"> must exist');
            assert.equal(label.control, toggle, 'label.control must resolve to the checkbox -- the real browser-computed label/control association, not mere DOM proximity');
            assert.equal(label.textContent.trim(), 'Kiosk Auto-Start', 'label text must match the shipped copy (relabelled from "Kiosk Mode" after the markup landed)');

            assert.equal(toggle.hasAttribute('disabled'), false, 'control must not be disabled');
            const tabindexAttr = toggle.getAttribute('tabindex');
            assert.ok(
                tabindexAttr === null || Number(tabindexAttr) >= 0,
                'control must not be removed from the tab order (tabindex="-1") -- this ticket is about a UI a user cannot otherwise dismiss, so a mouse-only off switch would be its own joke'
            );
        } finally { teardown(inst); }
    });
}

// ============================================================================
// FAB wiring -- lcars-kiosk.js's OWN DOMContentLoaded listener
// (document.getElementById('kiosk-enter-btn').addEventListener('click', ...))
// is a second, entirely separate binding seam from the toggle: it lives in
// shared/js/lcars-kiosk.js itself, wired independently of app.js. Subitem
// 006's resurrection-guard test (group (e)) calls LCARS_KIOSK.enter()
// directly via the API -- it never dispatches DOMContentLoaded, so that
// listener registration, and a real click on the real #kiosk-enter-btn
// element in lcars-dashboard.html, had never been executed either.
// ============================================================================

test('[lcars/lcars-dashboard.html] a real click on #kiosk-enter-btn enters kiosk mode via the FAB wiring', async () => {
    const spec = DASHBOARDS[0];
    const inst = loadDashboard(spec);
    try {
        await boot(inst);
        const fab = inst.document.getElementById('kiosk-enter-btn');
        assert.ok(fab, 'the #kiosk-enter-btn FAB must exist in the real markup');
        assert.equal(inst.K.isActive(), false, 'setup: kiosk must not be active yet');

        fab.dispatchEvent(new inst.window.Event('click', { bubbles: true }));
        assert.equal(inst.K.isActive(), true, 'a real click on the FAB must enter kiosk mode via lcars-kiosk.js\'s own DOMContentLoaded-registered listener');
    } finally { teardown(inst); }
});

test('[lcars/lcars-dashboard.html] manual FAB entry while the preference is OFF does not resurrect idle monitoring on exit', async () => {
    const spec = DASHBOARDS[0];
    const inst = loadDashboard(spec);
    try {
        setStoredPreference(inst.window, 'false');
        inst.K.config.idleTimeout = 30;
        await boot(inst);

        const toggle = getToggle(inst.document);
        assert.equal(toggle.checked, false, 'setup: preference starts OFF, reflected in the real toggle');

        const fab = inst.document.getElementById('kiosk-enter-btn');
        fab.dispatchEvent(new inst.window.Event('click', { bubbles: true }));
        assert.equal(inst.K.isActive(), true, 'setup: manual FAB entry activates kiosk even while the preference is OFF (entering is an explicit user action)');

        // The exit handler attaches after a 100ms delay (_setupKioskExitHandler).
        await wait(150);
        inst.document.dispatchEvent(new inst.window.Event('click', { bubbles: true, cancelable: true }));
        assert.equal(inst.K.isActive(), false, 'setup: the exit click must have exited kiosk');

        // The regression this whole ticket exists for: with the preference
        // still OFF, idle monitoring must not have been silently re-armed.
        await wait(80);
        assert.equal(inst.K.isActive(), false, 'exiting a manually-entered kiosk while the preference is OFF must not resurrect idle monitoring -- the toggle must stay authoritative');
        assert.equal(toggle.checked, false, 'the toggle itself must still read OFF -- nothing in this path should have touched the stored preference');
    } finally { teardown(inst); }
});

// ============================================================================
// XACA-1154-015 — kiosk exit hint
//
// Filed by the UX gate on PR #851: a user who has just escaped kiosk still has
// to rediscover the PREFERENCES panel unaided in order to stop it recurring.
// The hint is deliberately once-per-page-load and only when kiosk is still
// armed — a hint on EVERY exit would be its own undismissable nag, which is
// the defect class this whole ticket exists to close.
// ============================================================================

const HINT_SELECTOR = '.kiosk-exit-hint';

function hintEl(document) {
    return document.querySelector(HINT_SELECTOR);
}

test('(015) exiting kiosk with auto-start ON shows the hint pointing at Preferences', async () => {
    const inst = loadDashboard(DASHBOARDS[1]);
    try {
        setStoredPreference(inst.window, 'true');
        await boot(inst);

        assert.equal(hintEl(inst.document), null, 'no hint before kiosk has ever run');

        inst.K.enter();
        assert.equal(inst.K.isActive(), true, 'kiosk should have entered');
        await wait(150); // exit listeners attach after a 100ms setTimeout

        inst.document.dispatchEvent(new inst.window.Event('click', { bubbles: true }));
        assert.equal(inst.K.isActive(), false, 'a click must exit kiosk');

        const el = hintEl(inst.document);
        assert.ok(el, 'hint must be shown when kiosk is still armed to recur');

        // XACA-1154 round 3: the region is appended EMPTY and filled on the next
        // tick, deliberately — an aria-live region announces mutations observed
        // while it is already in the accessibility tree, so text arriving WITH
        // the node is not announceable. Await that tick before asserting text.
        await wait(20);
        assert.match(el.textContent, /Preferences/i, 'hint must name where the control lives');
        // Announced, not merely visible — this ticket is about an inescapable UI,
        // so a sighted-only affordance would miss the users most affected.
        assert.equal(el.getAttribute('role'), 'status');
        assert.equal(el.getAttribute('aria-live'), 'polite');
    } finally {
        teardown(inst);
    }
});

test('(015) the hint does NOT appear when auto-start is OFF (kiosk will not recur)', async () => {
    const inst = loadDashboard(DASHBOARDS[1]);
    try {
        setStoredPreference(inst.window, 'false');
        await boot(inst);

        // Manual entry is deliberately ungated, so this is reachable with the
        // preference off — and on exit there is nothing to warn about.
        inst.K.enter();
        await wait(150);
        inst.document.dispatchEvent(new inst.window.Event('click', { bubbles: true }));
        assert.equal(inst.K.isActive(), false, 'click must exit');

        assert.equal(hintEl(inst.document), null,
            'no hint when kiosk is disabled — there is nothing left to turn off');
    } finally {
        teardown(inst);
    }
});

test('(015) the hint is shown at most once per page load, not on every exit', async () => {
    const inst = loadDashboard(DASHBOARDS[1]);
    try {
        setStoredPreference(inst.window, 'true');
        await boot(inst);

        inst.K.enter();
        await wait(150);
        inst.document.dispatchEvent(new inst.window.Event('click', { bubbles: true }));
        assert.ok(hintEl(inst.document), 'first exit shows the hint');

        // Dismiss it, then go round again.
        hintEl(inst.document).dispatchEvent(new inst.window.Event('click', { bubbles: true }));
        assert.equal(hintEl(inst.document), null, 'clicking the hint dismisses it');

        inst.K.enter();
        await wait(150);
        inst.document.dispatchEvent(new inst.window.Event('click', { bubbles: true }));
        assert.equal(hintEl(inst.document), null,
            'second exit must NOT re-show the hint — repeating it is the nag this ticket exists to prevent');
    } finally {
        teardown(inst);
    }
});

test('(015) destroy() tears the hint down so no timer outlives the dashboard', async () => {
    const inst = loadDashboard(DASHBOARDS[1]);
    try {
        setStoredPreference(inst.window, 'true');
        await boot(inst);
        inst.K.enter();
        await wait(150);
        inst.document.dispatchEvent(new inst.window.Event('click', { bubbles: true }));
        assert.ok(hintEl(inst.document), 'hint present before destroy');

        inst.K.destroy();
        assert.equal(hintEl(inst.document), null, 'destroy() must remove the hint element');
    } finally {
        teardown(inst);
    }
});
