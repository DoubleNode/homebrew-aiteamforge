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

function setValue(document, id, value) {
    const el = document.getElementById(id);
    assert.ok(el, `expected #${id} to exist`);
    el.value = value;
}

/**
 * Stub window.fleetApiFetch (used by submitAddAccount/submitEditAccount, not
 * window.fetch, which loadEngines() uses and setupEnginesUI() already stubs)
 * and capture every call's method/url/parsed-JSON body, for the XACA-1342-029
 * request-body assertions below. Always resolves 2xx so the submit functions
 * proceed to their post-success loadEngines() refresh (window.fetch is stubbed
 * separately) without hitting the network.
 */
function stubFleetApiFetch(window) {
    const calls = [];
    window.fleetApiFetch = async function fakeFleetApiFetch(url, opts) {
        calls.push({
            url,
            method: (opts && opts.method) || 'GET',
            body: (opts && opts.body) ? JSON.parse(opts.body) : undefined,
        });
        return {
            ok: true,
            status: (opts && opts.method === 'POST') ? 201 : 200,
            json: async () => ({ slug: 'stub-account', account_id: 'stub-account' }),
        };
    };
    return calls;
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

    // -------------------------------------------------------------------
    // XACA-1342-026 — engine card ADD button + empty state wording
    // -------------------------------------------------------------------

    test(`${variant.name}: renderEngineCard for a secret-only engine uses '+ ADD SECRET' and 'No secrets registered yet' wording`, async () => {
        const { LCARS_ENGINES } = await setupEnginesUI(variant);

        const card = LCARS_ENGINES.renderEngineCard({
            slug: 'release-notify', name: 'Release Notify', kind: 'secret-only', accounts: []
        });

        const addBtn = card.querySelector('.engine-add-btn');
        assert.ok(addBtn, 'expected an ADD button on the card');
        assert.equal(addBtn.textContent, '+ ADD SECRET');

        const empty = card.querySelector('.engines-accounts-empty');
        assert.ok(empty, 'expected the empty-state element for a zero-account engine');
        assert.equal(empty.textContent, 'No secrets registered yet. Click + ADD SECRET to define one.');
    });

    test(`${variant.name}: renderEngineCard for a normal AI engine keeps '+ ADD ACCOUNT' wording (regression)`, async () => {
        const { LCARS_ENGINES } = await setupEnginesUI(variant);

        const card = LCARS_ENGINES.renderEngineCard({ slug: 'anthropic', name: 'Anthropic', accounts: [] });

        const addBtn = card.querySelector('.engine-add-btn');
        assert.equal(addBtn.textContent, '+ ADD ACCOUNT');

        const empty = card.querySelector('.engines-accounts-empty');
        assert.equal(empty.textContent, 'No accounts registered yet. Click + ADD ACCOUNT to define one.');
    });

    // -------------------------------------------------------------------
    // XACA-1342-027 — slug/nickname/env-var-hint label copy swap
    // -------------------------------------------------------------------

    test(`${variant.name}: ADD modal for a secret-only engine swaps slug label/placeholder/hint, nickname placeholder, and env-var hint copy`, async () => {
        const { document, LCARS_ENGINES } = await setupEnginesUI(variant);

        LCARS_ENGINES.openAddAccountModal(SECRET_ENGINE.slug, SECRET_ENGINE.name);

        assert.equal(text(document, 'engines-add-slug-label'), 'Secret Slug *');
        assert.equal(placeholder(document, 'engines-add-slug'), 'e.g. firebase-cr-approver');
        assert.equal(
            text(document, 'engines-add-slug-hint'),
            'lowercase-kebab-case — IMMUTABLE after creation (e.g. firebase-cr-approver)'
        );
        assert.equal(placeholder(document, 'engines-add-nickname'), 'e.g. Firebase CR Approver Webhook');
        assert.match(text(document, 'engines-add-env-var-hint'), /RELEASE_<TEAM>_<PURPOSE>/);
        assert.doesNotMatch(text(document, 'engines-add-env-var-hint'), /Claude Max/);
    });

    test(`${variant.name}: ADD modal for a normal AI engine keeps original slug/nickname/env-var-hint copy (regression)`, async () => {
        const { document, LCARS_ENGINES } = await setupEnginesUI(variant);

        LCARS_ENGINES.openAddAccountModal(AI_ENGINE.slug, AI_ENGINE.name);

        assert.equal(text(document, 'engines-add-slug-label'), 'Account Slug *');
        assert.equal(placeholder(document, 'engines-add-slug'), 'e.g. darren-personal');
        assert.equal(
            text(document, 'engines-add-slug-hint'),
            'lowercase-kebab-case — IMMUTABLE after creation (e.g. darren-personal)'
        );
        assert.equal(placeholder(document, 'engines-add-nickname'), 'e.g. Darren Personal Account');
        assert.match(text(document, 'engines-add-env-var-hint'), /Claude Max/);
    });

    test(`${variant.name}: opening the AI engine ADD modal after a secret-only one restores slug/nickname/env-var-hint copy too (regression)`, async () => {
        const { document, LCARS_ENGINES } = await setupEnginesUI(variant);

        LCARS_ENGINES.openAddAccountModal(SECRET_ENGINE.slug, SECRET_ENGINE.name);
        assert.equal(text(document, 'engines-add-slug-label'), 'Secret Slug *');

        LCARS_ENGINES.openAddAccountModal(AI_ENGINE.slug, AI_ENGINE.name);
        assert.equal(text(document, 'engines-add-slug-label'), 'Account Slug *');
        assert.equal(placeholder(document, 'engines-add-slug'), 'e.g. darren-personal');
        assert.equal(placeholder(document, 'engines-add-nickname'), 'e.g. Darren Personal Account');
        assert.match(text(document, 'engines-add-env-var-hint'), /Claude Max/);
    });

    test(`${variant.name}: EDIT modal for a secret-only engine's account swaps slug label and env-var hint copy`, async () => {
        const { document, LCARS_ENGINES } = await setupEnginesUI(variant);

        LCARS_ENGINES.openEditAccountModal(SECRET_ENGINE.slug, SECRET_ENGINE.accounts[0]);

        assert.equal(text(document, 'engines-edit-slug-label'), 'Secret Slug (IMMUTABLE)');
        assert.match(text(document, 'engines-edit-env-var-hint'), /RELEASE_<TEAM>_<PURPOSE>/);
        assert.doesNotMatch(text(document, 'engines-edit-env-var-hint'), /Claude Max/);
    });

    test(`${variant.name}: EDIT modal for a normal AI engine's account keeps original slug label and env-var hint copy (regression)`, async () => {
        const { document, LCARS_ENGINES } = await setupEnginesUI(variant);

        const aiAccount = {
            slug: 'darren-personal', account_id: 'acc_01AbCdEf',
            nickname: 'Darren Personal', env_var_name: 'ANTHROPIC_API_KEY_DARREN'
        };
        LCARS_ENGINES.openEditAccountModal(AI_ENGINE.slug, aiAccount);

        assert.equal(text(document, 'engines-edit-slug-label'), 'Account Slug (IMMUTABLE)');
        assert.match(text(document, 'engines-edit-env-var-hint'), /Claude Max/);
    });

    // -------------------------------------------------------------------
    // XACA-1342-028 / 029 — submitAddAccount/submitEditAccount request bodies
    // -------------------------------------------------------------------

    test(`${variant.name}: submitAddAccount for a secret-only engine omits account_id and auth_type from the POST body`, async () => {
        const { document, window, LCARS_ENGINES } = await setupEnginesUI(variant);
        const calls = stubFleetApiFetch(window);

        LCARS_ENGINES.openAddAccountModal(SECRET_ENGINE.slug, SECRET_ENGINE.name);
        setValue(document, 'engines-add-slug', 'new-secret');
        setValue(document, 'engines-add-nickname', 'New Secret');
        setValue(document, 'engines-add-env-var', 'RELEASE_NEW_SECRET');

        await LCARS_ENGINES.submitAddAccount();

        assert.equal(calls.length, 1, 'expected exactly one fleetApiFetch call');
        assert.equal(calls[0].method, 'POST');
        assert.equal(calls[0].url, `/api/engines/${SECRET_ENGINE.slug}/accounts`);
        assert.deepEqual(
            Object.keys(calls[0].body).sort(),
            ['env_var_name', 'nickname', 'slug'].sort()
        );
        assert.equal('account_id' in calls[0].body, false, 'account_id must be omitted, not sent blank');
        assert.equal('auth_type' in calls[0].body, false, 'auth_type must be omitted entirely on POST for a secret-only engine');
    });

    test(`${variant.name}: submitAddAccount for a normal AI engine keeps account_id required, auth_type optional (regression)`, async () => {
        const { document, window, LCARS_ENGINES } = await setupEnginesUI(variant);
        const calls = stubFleetApiFetch(window);

        LCARS_ENGINES.openAddAccountModal(AI_ENGINE.slug, AI_ENGINE.name);
        setValue(document, 'engines-add-slug', 'darren-work');
        setValue(document, 'engines-add-account-id', 'acc_ai_test');
        setValue(document, 'engines-add-nickname', 'Darren Work');
        setValue(document, 'engines-add-env-var', 'ANTHROPIC_API_KEY_DARREN_WORK');

        await LCARS_ENGINES.submitAddAccount();

        assert.equal(calls.length, 1);
        assert.equal(calls[0].body.account_id, 'acc_ai_test');
        assert.equal('auth_type' in calls[0].body, false, 'no Auth Type selected -> key omitted (unchanged POST semantics)');
    });

    test(`${variant.name}: submitEditAccount for a secret-only engine's account sends auth_type: null and no account_id when unset`, async () => {
        const { window, LCARS_ENGINES } = await setupEnginesUI(variant);
        const calls = stubFleetApiFetch(window);

        // A secret-only account that has never had an account_id assigned
        // (e.g. a legacy record predating the slug-default) -- the Account ID
        // field is hidden for secret-only engines, so it opens blank.
        const legacyAccount = {
            slug: 'legacy-secret-no-id',
            nickname: 'Legacy Secret No Id',
            env_var_name: 'RELEASE_LEGACY_SECRET_NO_ID',
        };
        LCARS_ENGINES.openEditAccountModal(SECRET_ENGINE.slug, legacyAccount);

        await LCARS_ENGINES.submitEditAccount();

        assert.equal(calls.length, 1, 'expected exactly one fleetApiFetch call');
        assert.equal(calls[0].method, 'PUT');
        assert.equal(calls[0].url, `/api/engines/${SECRET_ENGINE.slug}/accounts/${legacyAccount.slug}`);
        assert.equal(calls[0].body.auth_type, null, 'auth_type must be explicit null, never omitted, for a secret-only edit (XACA-1342-028)');
        assert.equal('account_id' in calls[0].body, false, 'account_id omitted when blank so the server slug-default applies');
    });

    test(`${variant.name}: submitEditAccount for a normal AI engine's account always sends auth_type (regression)`, async () => {
        const { window, LCARS_ENGINES } = await setupEnginesUI(variant);
        const calls = stubFleetApiFetch(window);

        const aiAccount = {
            slug: 'darren-personal', account_id: 'acc_01AbCdEf',
            nickname: 'Darren Personal', env_var_name: 'ANTHROPIC_API_KEY_DARREN'
        };
        LCARS_ENGINES.openEditAccountModal(AI_ENGINE.slug, aiAccount);

        await LCARS_ENGINES.submitEditAccount();

        assert.equal(calls.length, 1);
        assert.equal(calls[0].body.account_id, 'acc_01AbCdEf');
        assert.equal(calls[0].body.auth_type, null, 'no Auth Type selected -> explicit null (unchanged PUT semantics)');
    });

    test(`${variant.name}: submitEditAccount for a normal AI engine's account sends the selected auth_type enum value (regression)`, async () => {
        const { window, LCARS_ENGINES } = await setupEnginesUI(variant);
        const calls = stubFleetApiFetch(window);

        const aiAccount = {
            slug: 'darren-personal', account_id: 'acc_01AbCdEf',
            nickname: 'Darren Personal', env_var_name: 'ANTHROPIC_API_KEY_DARREN',
            auth_type: 'oauth_token'
        };
        LCARS_ENGINES.openEditAccountModal(AI_ENGINE.slug, aiAccount);

        await LCARS_ENGINES.submitEditAccount();

        assert.equal(calls[0].body.auth_type, 'oauth_token');
    });

    // -------------------------------------------------------------------
    // XACA-1342-030 — accounts table column visibility
    // -------------------------------------------------------------------

    test(`${variant.name}: renderAccountTable for a secret-only engine hides ACCOUNT ID / AUTH TYPE / LAST VALIDATED columns`, async () => {
        const { LCARS_ENGINES } = await setupEnginesUI(variant);

        const wrapper = LCARS_ENGINES.renderAccountTable(SECRET_ENGINE);
        const headers = Array.from(wrapper.querySelectorAll('thead th')).map((th) => th.textContent);
        assert.deepEqual(headers, ['NICKNAME', 'ENV VAR', 'VAULT', 'CREATED', 'ACTIONS']);

        const row = wrapper.querySelector('tbody tr');
        assert.ok(row, 'expected one account row');
        assert.equal(row.querySelector('.engine-col-account-id'), null);
        assert.equal(row.querySelector('.engine-col-auth-type'), null);
        assert.equal(row.querySelector('.engine-col-validated'), null);
        assert.ok(row.querySelector('.engine-col-nickname'));
        assert.ok(row.querySelector('.engine-col-env-var'));
        assert.ok(row.querySelector('.engine-col-vault'));
        assert.ok(row.querySelector('.engine-col-created'));
        assert.ok(row.querySelector('.engine-col-actions'));
    });

    test(`${variant.name}: renderAccountTable for a normal AI engine keeps all columns (regression)`, async () => {
        const { LCARS_ENGINES } = await setupEnginesUI(variant);

        const aiEngineWithAccount = {
            slug: AI_ENGINE.slug,
            name: AI_ENGINE.name,
            accounts: [{
                slug: 'darren-personal',
                account_id: 'acc_01AbCdEf',
                nickname: 'Darren Personal',
                env_var_name: 'ANTHROPIC_API_KEY_DARREN',
                auth_type: 'oauth_token',
                created_at: '2026-01-01T00:00:00.000Z',
                last_validated_at: null,
            }],
        };

        const wrapper = LCARS_ENGINES.renderAccountTable(aiEngineWithAccount);
        const headers = Array.from(wrapper.querySelectorAll('thead th')).map((th) => th.textContent);
        assert.deepEqual(
            headers,
            ['NICKNAME', 'ACCOUNT ID', 'ENV VAR', 'AUTH TYPE', 'VAULT', 'CREATED', 'LAST VALIDATED', 'ACTIONS']
        );

        const row = wrapper.querySelector('tbody tr');
        assert.ok(row.querySelector('.engine-col-account-id'));
        assert.ok(row.querySelector('.engine-col-auth-type'));
        assert.ok(row.querySelector('.engine-col-validated'));
    });

    test(`${variant.name}: renderAccountRow defaults secretOnly via the cached engines list when the caller omits it`, async () => {
        const { LCARS_ENGINES } = await setupEnginesUI(variant);

        const row = LCARS_ENGINES.renderAccountRow(SECRET_ENGINE.slug, SECRET_ENGINE.accounts[0]);
        assert.equal(row.querySelector('.engine-col-account-id'), null, 'secretOnly must be inferred, hiding the column');
    });
}
