//
//  xaca-1342-025-secret-only-modal-ux-jsdom.test.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

'use strict';

/**
 * XACA-1342-025 (UX advisory, folded in after PR #974): the Fleet Monitor
 * Engines tab's ADD/EDIT ACCOUNT modal was Anthropic-shaped for every engine,
 * including secret-only engines (`kind: "secret-only"`, e.g. release-notify /
 * release-wiki) that hold a webhook URL or opaque token, not an Anthropic
 * account. An admin registering one of those had to invent an Account ID and
 * pick from an OAuth/API Key/Gateway Auth Type list that describes nothing
 * about a webhook token.
 *
 * This suite loads the REAL shipped lcars/lcars-dashboard.html plus the REAL
 * shipped lcars/js/lcars-engines.js (and the lcars2 variant against its own
 * real HTML) into jsdom via vm.runInContext — never a paraphrase of the
 * logic — same discipline and load pattern as
 * tests/xaca-1060-008-machine-filter-jsdom.test.js, whose house style this
 * file follows (including the "wait for jsdom's own load event before
 * injecting any script" rule, since lcars-engines.js registers a
 * DOMContentLoaded listener at module scope on load).
 *
 * Covers, per variant (lcars, lcars2):
 *   - openAddAccountModal() / openEditAccountModal() for a secret-only engine:
 *     Account ID and Auth Type field groups are hidden, the modal title reads
 *     ADD/EDIT SECRET, the lead sentence reads "Adding secret to:", the Env
 *     Var Name placeholder uses RELEASE_<TEAM>_<PURPOSE> wording, and the
 *     Secret Value placeholder uses webhook/token wording.
 *   - The same two functions for a normal AI engine render EXACTLY as before
 *     (regression): both field groups visible, ADD/EDIT ACCOUNT title,
 *     "Adding account to engine:" lead, ANTHROPIC_API_KEY_* env-var
 *     placeholder, "paste the API key..." secret placeholder.
 *   - The ENGINES section header no longer reads "AI ENGINES".
 *
 * No network fetch is exercised here — engines are fed to the module's
 * internal cache via loadEngines() with window.fetch stubbed to resolve a
 * canned /api/engines payload, so this suite never touches a real server.
 */

const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const PUBLIC_ROOT = path.join(__dirname, '..', 'public');

const VARIANTS = [
    { name: 'lcars',  html: 'lcars/lcars-dashboard.html',    js: 'lcars/js/lcars-engines.js' },
    { name: 'lcars2', html: 'lcars2/lcars-mainevent.html',   js: 'lcars2/js/lcars-engines.js' },
];

const SECRET_ENGINE = {
    slug: 'release-notify',
    name: 'Release Notify',
    kind: 'secret-only',
    accounts: [{
        slug: 'firebase-cr-approver',
        account_id: 'firebase-cr-approver',
        nickname: 'Firebase CR Approver',
        env_var_name: 'RELEASE_FIREBASE_CR_APPROVER',
        created_at: '2026-01-01T00:00:00.000Z',
        updated_at: '2026-01-01T00:00:00.000Z',
        last_validated_at: null,
    }],
};

const AI_ENGINE = {
    slug: 'anthropic',
    name: 'Anthropic',
    accounts: [],
};

const FIXTURE_ENGINES = [SECRET_ENGINE, AI_ENGINE];

/**
 * Loads the REAL dashboard HTML into jsdom, waits for jsdom's own 'load'
 * event (so lcars-engines.js's DOMContentLoaded-gated init() sees
 * document.readyState === 'complete' and runs synchronously instead of
 * registering a listener for an event that already fired -- same rationale
 * as tests/xaca-1060-008-machine-filter-jsdom.test.js's setupDashboard()),
 * stubs window.fetch, then evaluates the real engines UI script.
 */
async function setupEnginesUI(variant) {
    const html = fs.readFileSync(path.join(PUBLIC_ROOT, variant.html), 'utf8');
    const dom = new JSDOM(html, {
        url: 'http://lcars-test.local/' + variant.html,
        runScripts: 'outside-only',
        pretendToBeVisual: true,
    });
    const window = dom.window;
    const document = window.document;

    await new Promise((resolve) => {
        if (document.readyState === 'complete') { resolve(); return; }
        window.addEventListener('load', () => resolve(), { once: true });
    });

    // Stub fetch BEFORE the script evaluates -- loadEngines() reads
    // window.fetch (global `fetch` inside the vm context resolves to the
    // window's) at call time, so this only needs to exist before we call it,
    // but setting it up front keeps the ordering simple and explicit.
    window.fetch = async function fakeFetch() {
        return {
            ok: true,
            status: 200,
            statusText: 'OK',
            json: async () => ({
                engines: JSON.parse(JSON.stringify(FIXTURE_ENGINES)),
                updated_at: '2026-01-01T00:00:00.000Z',
            }),
        };
    };

    const ctx = dom.getInternalVMContext();
    const src = fs.readFileSync(path.join(PUBLIC_ROOT, variant.js), 'utf8');
    vm.runInContext(src, ctx, { filename: variant.js });

    const LCARS_ENGINES = window.LCARS_ENGINES;
    if (!LCARS_ENGINES || typeof LCARS_ENGINES.loadEngines !== 'function') {
        throw new Error('setupEnginesUI: window.LCARS_ENGINES missing from ' + variant.js);
    }

    // Populate the module's internal _engines cache (used by
    // isSecretOnlyEngineSlug()) via the real fetch path.
    await LCARS_ENGINES.loadEngines();

    return { window, document, LCARS_ENGINES };
}

function hidden(document, id) {
    const el = document.getElementById(id);
    assert.ok(el, `expected #${id} to exist`);
    return el.hidden;
}

function text(document, id) {
    const el = document.getElementById(id);
    assert.ok(el, `expected #${id} to exist`);
    return el.textContent;
}

function placeholder(document, id) {
    const el = document.getElementById(id);
    assert.ok(el, `expected #${id} to exist`);
    return el.placeholder;
}

for (const variant of VARIANTS) {
    test(`${variant.name}: harness sanity -- real HTML + real lcars-engines.js load, engines fetch stub resolves both fixture engines`, async () => {
        const { document } = await setupEnginesUI(variant);
        assert.ok(document.getElementById('engines-container'), 'real dashboard HTML must contain #engines-container');
        assert.ok(document.getElementById('engines-add-account-id-group'), 'ADD modal must carry the account-id group id this suite hides/shows');
        assert.ok(document.getElementById('engines-add-auth-type-group'), 'ADD modal must carry the auth-type group id this suite hides/shows');
        assert.ok(document.getElementById('engines-edit-account-id-group'), 'EDIT modal must carry the account-id group id this suite hides/shows');
        assert.ok(document.getElementById('engines-edit-auth-type-group'), 'EDIT modal must carry the auth-type group id this suite hides/shows');
    });

    test(`${variant.name}: ENGINES section header no longer reads "AI ENGINES"`, async () => {
        const { document } = await setupEnginesUI(variant);
        const titleEl = document.querySelector('.lcars-section[data-section="engines"] .section-title');
        assert.ok(titleEl, 'expected a .section-title inside the engines section');
        assert.equal(titleEl.textContent, 'ENGINES');
    });

    // -------------------------------------------------------------------
    // ADD modal — secret-only engine
    // -------------------------------------------------------------------

    test(`${variant.name}: ADD modal for a secret-only engine hides Account ID + Auth Type, uses webhook/token wording`, async () => {
        const { document, LCARS_ENGINES } = await setupEnginesUI(variant);

        LCARS_ENGINES.openAddAccountModal(SECRET_ENGINE.slug, SECRET_ENGINE.name);

        assert.equal(hidden(document, 'engines-add-account-id-group'), true, 'Account ID group must be hidden for a secret-only engine');
        assert.equal(hidden(document, 'engines-add-auth-type-group'), true, 'Auth Type group must be hidden for a secret-only engine');
        assert.equal(text(document, 'engines-add-modal-title'), 'ADD SECRET');
        assert.equal(text(document, 'engines-add-modal-lead'), 'Adding secret to:');
        assert.equal(placeholder(document, 'engines-add-env-var'), 'e.g. RELEASE_FIREBASE_CR_APPROVER');
        assert.equal(
            placeholder(document, 'engines-add-secret'),
            'paste the webhook URL or API token to seal it to authorized machines'
        );
        assert.doesNotMatch(placeholder(document, 'engines-add-secret'), /API key/i);
        assert.doesNotMatch(placeholder(document, 'engines-add-env-var'), /ANTHROPIC/);
    });

    // -------------------------------------------------------------------
    // ADD modal — AI engine (regression: unchanged)
    // -------------------------------------------------------------------

    test(`${variant.name}: ADD modal for a normal AI engine renders EXACTLY as before (regression)`, async () => {
        const { document, LCARS_ENGINES } = await setupEnginesUI(variant);

        LCARS_ENGINES.openAddAccountModal(AI_ENGINE.slug, AI_ENGINE.name);

        assert.equal(hidden(document, 'engines-add-account-id-group'), false, 'Account ID group must stay visible for an AI engine');
        assert.equal(hidden(document, 'engines-add-auth-type-group'), false, 'Auth Type group must stay visible for an AI engine');
        assert.equal(text(document, 'engines-add-modal-title'), 'ADD ACCOUNT');
        assert.equal(text(document, 'engines-add-modal-lead'), 'Adding account to engine:');
        assert.equal(placeholder(document, 'engines-add-env-var'), 'e.g. ANTHROPIC_API_KEY_DARREN or CLAUDE_ACCT_ME_TOKEN');
        assert.equal(placeholder(document, 'engines-add-secret'), 'paste the API key to seal it to authorized machines');
    });

    // Regression across a state transition: secret-only modal opened first,
    // then an AI engine's modal must fully restore the original wording (no
    // leftover hidden groups / titles / placeholders from the prior open).
    test(`${variant.name}: opening the AI engine ADD modal after a secret-only one restores original state`, async () => {
        const { document, LCARS_ENGINES } = await setupEnginesUI(variant);

        LCARS_ENGINES.openAddAccountModal(SECRET_ENGINE.slug, SECRET_ENGINE.name);
        assert.equal(hidden(document, 'engines-add-account-id-group'), true);

        LCARS_ENGINES.openAddAccountModal(AI_ENGINE.slug, AI_ENGINE.name);
        assert.equal(hidden(document, 'engines-add-account-id-group'), false);
        assert.equal(hidden(document, 'engines-add-auth-type-group'), false);
        assert.equal(text(document, 'engines-add-modal-title'), 'ADD ACCOUNT');
        assert.equal(placeholder(document, 'engines-add-secret'), 'paste the API key to seal it to authorized machines');
    });

    // -------------------------------------------------------------------
    // EDIT modal — secret-only engine
    // -------------------------------------------------------------------

    test(`${variant.name}: EDIT modal for a secret-only engine's account hides Account ID + Auth Type, uses webhook/token wording`, async () => {
        const { document, LCARS_ENGINES } = await setupEnginesUI(variant);

        LCARS_ENGINES.openEditAccountModal(SECRET_ENGINE.slug, SECRET_ENGINE.accounts[0]);

        assert.equal(hidden(document, 'engines-edit-account-id-group'), true, 'Account ID group must be hidden for a secret-only engine');
        assert.equal(hidden(document, 'engines-edit-auth-type-group'), true, 'Auth Type group must be hidden for a secret-only engine');
        assert.equal(text(document, 'engines-edit-modal-title'), 'EDIT SECRET');
        assert.equal(placeholder(document, 'engines-edit-env-var'), 'e.g. RELEASE_FIREBASE_CR_APPROVER');
        assert.equal(
            placeholder(document, 'engines-edit-secret'),
            'enter a new webhook URL or token to re-seal; blank = unchanged'
        );
    });

    // -------------------------------------------------------------------
    // EDIT modal — AI engine (regression: unchanged)
    // -------------------------------------------------------------------

    test(`${variant.name}: EDIT modal for a normal AI engine's account renders EXACTLY as before (regression)`, async () => {
        const { document, LCARS_ENGINES } = await setupEnginesUI(variant);

        const aiAccount = {
            slug: 'darren-personal',
            account_id: 'acc_01AbCdEf',
            nickname: 'Darren Personal',
            env_var_name: 'ANTHROPIC_API_KEY_DARREN',
        };
        LCARS_ENGINES.openEditAccountModal(AI_ENGINE.slug, aiAccount);

        assert.equal(hidden(document, 'engines-edit-account-id-group'), false, 'Account ID group must stay visible for an AI engine');
        assert.equal(hidden(document, 'engines-edit-auth-type-group'), false, 'Auth Type group must stay visible for an AI engine');
        assert.equal(text(document, 'engines-edit-modal-title'), 'EDIT ACCOUNT');
        assert.equal(placeholder(document, 'engines-edit-env-var'), 'e.g. ANTHROPIC_API_KEY_DARREN or CLAUDE_ACCT_ME_TOKEN');
        assert.equal(placeholder(document, 'engines-edit-secret'), 'enter a new value to re-seal; blank = unchanged');

        // The edit form fields must still be populated from the account object.
        assert.equal(document.getElementById('engines-edit-account-id').value, 'acc_01AbCdEf');
        assert.equal(document.getElementById('engines-edit-nickname').value, 'Darren Personal');
    });
}
