//
//  lcars-engines.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

// === XACA-0281: AI Engines Registry UI ===

(function() {
    'use strict';

    // =========================================================================
    // CONFIG
    // =========================================================================

    const ENGINES_API = '/api/engines';

    // Validation regexes — mirror server-side rules
    const SLUG_RE     = /^[a-z][a-z0-9-]*$/;
    const ENV_VAR_RE  = /^[A-Z][A-Z0-9_]*$/;
    const MAX_LEN     = 200;

    // =========================================================================
    // STATE
    // =========================================================================

    // Current engine slug being operated on by modals
    var _activeEngineSlug  = null;
    var _activeAccountSlug = null;
    var _initialized       = false;

    // =========================================================================
    // PUBLIC API (attached to window.LCARS_ENGINES)
    // =========================================================================

    var LCARS_ENGINES = {

        /**
         * Fetch /api/engines and render all engine cards into #engines-container.
         */
        async loadEngines() {
            var container = document.getElementById('engines-container');
            if (!container) return;

            container.innerHTML = '<div class="engines-loading">LOADING...</div>';

            try {
                var resp = await fetch(ENGINES_API);
                if (!resp.ok) {
                    throw new Error('HTTP ' + resp.status + ': ' + resp.statusText);
                }
                var data = await resp.json();
                var engines = (data && data.engines) ? data.engines : [];

                container.innerHTML = '';
                if (engines.length === 0) {
                    container.innerHTML = '<div class="engines-empty">No AI engines registered.</div>';
                    return;
                }
                engines.forEach(function(engine) {
                    container.appendChild(LCARS_ENGINES.renderEngineCard(engine));
                });

                // Update subtitle timestamp
                var ts = document.getElementById('engines-updated-ts');
                if (ts && data.updated_at) {
                    ts.textContent = new Date(data.updated_at).toLocaleString();
                }

            } catch (err) {
                console.error('[ENGINES] loadEngines error:', err);
                container.innerHTML = '<div class="engines-error">Error loading engines: ' + escHtml(err.message) + '</div>';
            }
        },

        /**
         * Build the card DOM element for one engine.
         * @param {object} engine - { slug, name, accounts: [...] }
         * @returns {HTMLElement}
         */
        renderEngineCard(engine) {
            var card = document.createElement('div');
            card.className = 'engine-card';
            card.id = 'engine-card-' + escHtml(engine.slug);

            var header = document.createElement('div');
            header.className = 'engine-card-header';

            var nameEl = document.createElement('span');
            nameEl.className = 'engine-card-name';
            nameEl.textContent = engine.name || engine.slug;

            var addBtn = document.createElement('button');
            addBtn.className = 'btn-lcars btn-lcars-new engine-add-btn';
            addBtn.textContent = '+ ADD ACCOUNT';
            addBtn.addEventListener('click', function() {
                LCARS_ENGINES.openAddAccountModal(engine.slug, engine.name || engine.slug);
            });

            header.appendChild(nameEl);
            header.appendChild(addBtn);
            card.appendChild(header);

            var body = document.createElement('div');
            body.className = 'engine-card-body';
            body.id = 'engine-accounts-' + escHtml(engine.slug);

            if (!engine.accounts || engine.accounts.length === 0) {
                var empty = document.createElement('div');
                empty.className = 'engines-accounts-empty';
                empty.textContent = 'No accounts registered yet. Click + ADD ACCOUNT to define one.';
                body.appendChild(empty);
            } else {
                body.appendChild(LCARS_ENGINES.renderAccountTable(engine));
            }

            card.appendChild(body);
            return card;
        },

        /**
         * Build the accounts table for an engine.
         * @param {object} engine
         * @returns {HTMLElement}
         */
        renderAccountTable(engine) {
            var wrapper = document.createElement('div');
            wrapper.className = 'engine-accounts-table-wrapper';

            var table = document.createElement('table');
            table.className = 'engine-accounts-table';

            var thead = document.createElement('thead');
            thead.innerHTML = '<tr>' +
                '<th>NICKNAME</th>' +
                '<th>ACCOUNT ID</th>' +
                '<th>ENV VAR</th>' +
                '<th>VAULT</th>' +
                '<th>CREATED</th>' +
                '<th>LAST VALIDATED</th>' +
                '<th>ACTIONS</th>' +
                '</tr>';
            table.appendChild(thead);

            var tbody = document.createElement('tbody');
            engine.accounts.forEach(function(account) {
                tbody.appendChild(LCARS_ENGINES.renderAccountRow(engine.slug, account));
            });
            table.appendChild(tbody);

            wrapper.appendChild(table);
            return wrapper;
        },

        /**
         * Build one table row for an account.
         * @param {string} engineSlug
         * @param {object} account - { slug, account_id, nickname, env_var_name, created_at, last_validated_at }
         * @returns {HTMLTableRowElement}
         */
        renderAccountRow(engineSlug, account) {
            var tr = document.createElement('tr');
            tr.id = 'account-row-' + escHtml(engineSlug) + '-' + escHtml(account.slug);

            var accountIdDisplay = account.account_id
                ? (account.account_id.substring(0, 12) + (account.account_id.length > 12 ? '...' : ''))
                : '—';

            tr.innerHTML = [
                '<td class="engine-col-nickname">' + escHtml(account.nickname || '—') + '</td>',
                '<td class="engine-col-account-id" title="' + escHtml(account.account_id || '') + '">' +
                    '<code>' + escHtml(accountIdDisplay) + '</code></td>',
                '<td class="engine-col-env-var"><code>' + escHtml(account.env_var_name || '—') + '</code></td>',
                '<td class="engine-col-vault">' + vaultBadge(account) + '</td>',
                '<td class="engine-col-created">' + fmtDate(account.created_at) + '</td>',
                '<td class="engine-col-validated">' + fmtDate(account.last_validated_at) + '</td>',
                '<td class="engine-col-actions"></td>'
            ].join('');

            var actionsCell = tr.querySelector('.engine-col-actions');

            var editBtn = document.createElement('button');
            editBtn.className = 'btn-lcars btn-lcars-secondary engine-action-btn';
            editBtn.textContent = 'EDIT';
            editBtn.addEventListener('click', function() {
                LCARS_ENGINES.openEditAccountModal(engineSlug, account);
            });

            var deleteBtn = document.createElement('button');
            deleteBtn.className = 'btn-lcars btn-lcars-danger engine-action-btn';
            deleteBtn.textContent = 'DELETE';
            deleteBtn.addEventListener('click', function() {
                LCARS_ENGINES.openDeleteConfirmModal(engineSlug, account.slug);
            });

            actionsCell.appendChild(editBtn);
            actionsCell.appendChild(deleteBtn);

            return tr;
        },

        // =====================================================================
        // MODALS — ADD
        // =====================================================================

        openAddAccountModal(engineSlug, engineName) {
            _activeEngineSlug  = engineSlug;
            _activeAccountSlug = null;

            document.getElementById('engines-add-engine-label').textContent = engineName;
            document.getElementById('engines-add-slug').value         = '';
            document.getElementById('engines-add-account-id').value   = '';
            document.getElementById('engines-add-nickname').value     = '';
            document.getElementById('engines-add-env-var').value      = '';
            // Write-only secret field: always start empty (never echoed back). XACA-0538-001.
            var addSecret = document.getElementById('engines-add-secret');
            if (addSecret) addSecret.value = '';

            clearAddErrors();
            showModal('engines-add-modal');
        },

        // =====================================================================
        // MODALS — EDIT
        // =====================================================================

        openEditAccountModal(engineSlug, account) {
            _activeEngineSlug  = engineSlug;
            _activeAccountSlug = account.slug;

            document.getElementById('engines-edit-slug').value       = account.slug;
            document.getElementById('engines-edit-account-id').value = account.account_id  || '';
            document.getElementById('engines-edit-nickname').value   = account.nickname    || '';
            document.getElementById('engines-edit-env-var').value    = account.env_var_name || '';
            // Write-only secret field: MUST open EMPTY on edit — the plaintext is never
            // available to echo. Empty on save = leave the existing sealed secret unchanged.
            // XACA-0538-001.
            var editSecret = document.getElementById('engines-edit-secret');
            if (editSecret) editSecret.value = '';

            clearEditErrors();
            showModal('engines-edit-modal');
        },

        // =====================================================================
        // MODALS — DELETE
        // =====================================================================

        async openDeleteConfirmModal(engineSlug, accountSlug) {
            _activeEngineSlug  = engineSlug;
            _activeAccountSlug = accountSlug;

            document.getElementById('engines-delete-slug-label').textContent = accountSlug;

            var usageInfo   = document.getElementById('engines-delete-usage-info');
            var confirmBtn  = document.getElementById('engines-delete-confirm-btn');
            var serverErrEl = document.getElementById('engines-delete-server-err');

            usageInfo.innerHTML  = '<div style="color: rgba(255,204,153,0.5); font-size: 12px;">Checking usage...</div>';
            confirmBtn.disabled  = true;
            serverErrEl.style.display = 'none';

            showModal('engines-delete-modal');

            // Dry-run DELETE (no ?confirm=true) to get usage info
            try {
                var resp = await fetch(
                    ENGINES_API + '/' + encodeURIComponent(engineSlug) +
                    '/accounts/' + encodeURIComponent(accountSlug),
                    { method: 'DELETE' }
                );
                var data = await resp.json();

                if (!resp.ok) {
                    usageInfo.innerHTML = '<div class="form-error">Could not check usage: ' + escHtml(data.error || 'Unknown error') + '</div>';
                    return;
                }

                var usage = data.usage || [];
                if (usage.length === 0) {
                    usageInfo.innerHTML = '<div class="engines-usage-ok">Not currently in use by any team.</div>';
                } else {
                    usageInfo.innerHTML =
                        '<div class="engines-usage-warn">This account is currently used by ' + usage.length + ' team(s):</div>' +
                        '<ul class="engines-usage-list">' +
                        usage.map(function(u) { return '<li>' + escHtml(u) + '</li>'; }).join('') +
                        '</ul>';
                }
                confirmBtn.disabled = false;

            } catch (err) {
                console.error('[ENGINES] dry-run delete error:', err);
                usageInfo.innerHTML = '<div class="form-error">Failed to check usage: ' + escHtml(err.message) + '</div>';
            }
        },

        // =====================================================================
        // SUBMIT — ADD
        // =====================================================================

        async submitAddAccount() {
            var slug      = (document.getElementById('engines-add-slug').value || '').trim();
            var accountId = (document.getElementById('engines-add-account-id').value || '').trim();
            var nickname  = (document.getElementById('engines-add-nickname').value || '').trim();
            var envVar    = (document.getElementById('engines-add-env-var').value || '').trim();
            // Secret value is NOT trimmed — a secret may legitimately contain whitespace.
            var secretEl  = document.getElementById('engines-add-secret');
            var secret    = secretEl ? (secretEl.value || '') : '';

            clearAddErrors();

            var valid = true;
            if (!slug) {
                showFieldError('engines-add-slug-err', 'Slug is required.');
                valid = false;
            } else if (!SLUG_RE.test(slug)) {
                showFieldError('engines-add-slug-err', 'Must match ^[a-z][a-z0-9-]*$ (lowercase-kebab-case).');
                valid = false;
            } else if (slug.length > 64) {
                showFieldError('engines-add-slug-err', 'Max 64 characters.');
                valid = false;
            }

            if (!accountId) {
                showFieldError('engines-add-account-id-err', 'Account ID is required.');
                valid = false;
            } else if (accountId.length > MAX_LEN) {
                showFieldError('engines-add-account-id-err', 'Max ' + MAX_LEN + ' characters.');
                valid = false;
            }

            if (!nickname) {
                showFieldError('engines-add-nickname-err', 'Nickname is required.');
                valid = false;
            } else if (nickname.length > MAX_LEN) {
                showFieldError('engines-add-nickname-err', 'Max ' + MAX_LEN + ' characters.');
                valid = false;
            }

            if (!envVar) {
                showFieldError('engines-add-env-var-err', 'Env var name is required.');
                valid = false;
            } else if (!ENV_VAR_RE.test(envVar)) {
                showFieldError('engines-add-env-var-err', 'Must match ^[A-Z][A-Z0-9_]*$ (e.g. ANTHROPIC_API_KEY_DARREN).');
                valid = false;
            }

            if (!valid) return;

            var saveBtn = document.getElementById('engines-add-save-btn');
            saveBtn.disabled = true;
            saveBtn.textContent = 'SAVING...';

            try {
                var resp = await fetch(
                    ENGINES_API + '/' + encodeURIComponent(_activeEngineSlug) + '/accounts',
                    {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({ slug: slug, account_id: accountId, nickname: nickname, env_var_name: envVar })
                    }
                );
                var data = await resp.json();

                if (!resp.ok) {
                    showServerError('engines-add-server-err', data.error || 'Server error (' + resp.status + ')');
                    return;
                }

                // If a secret value was supplied, seal it client-side and store it.
                // The account was just created, so the new secret cannot pre-exist;
                // POST is correct (409 only if a stray secret already exists). XACA-0538-001.
                if (secret) {
                    var sealedOk = await sealAndStoreSecret(
                        _activeEngineSlug, slug, secret, 'POST', 'engines-add-secret-err'
                    );
                    secret = ''; // drop our reference to plaintext ASAP
                    if (secretEl) secretEl.value = '';
                    if (!sealedOk) {
                        // Account saved but secret sealing failed: keep the modal open so
                        // the user can retry the secret via Edit. Refresh the list so the
                        // new account (without a vault secret yet) shows.
                        await LCARS_ENGINES.loadEngines();
                        return;
                    }
                }

                hideModal('engines-add-modal');
                await LCARS_ENGINES.loadEngines();

            } catch (err) {
                console.error('[ENGINES] submitAddAccount error:', err);
                showServerError('engines-add-server-err', 'Network error: ' + err.message);
            } finally {
                secret = ''; // belt-and-suspenders: never leave plaintext in scope
                if (secretEl) secretEl.value = '';
                saveBtn.disabled = false;
                saveBtn.textContent = 'SAVE';
            }
        },

        // =====================================================================
        // SUBMIT — EDIT
        // =====================================================================

        async submitEditAccount() {
            var accountId = (document.getElementById('engines-edit-account-id').value || '').trim();
            var nickname  = (document.getElementById('engines-edit-nickname').value || '').trim();
            var envVar    = (document.getElementById('engines-edit-env-var').value || '').trim();
            // Secret value is NOT trimmed. Empty == leave the existing sealed secret
            // unchanged (write-only field; plaintext is never echoed). XACA-0538-001.
            var secretEl  = document.getElementById('engines-edit-secret');
            var secret    = secretEl ? (secretEl.value || '') : '';

            clearEditErrors();

            var valid = true;
            if (!accountId) {
                showFieldError('engines-edit-account-id-err', 'Account ID is required.');
                valid = false;
            } else if (accountId.length > MAX_LEN) {
                showFieldError('engines-edit-account-id-err', 'Max ' + MAX_LEN + ' characters.');
                valid = false;
            }

            if (!nickname) {
                showFieldError('engines-edit-nickname-err', 'Nickname is required.');
                valid = false;
            } else if (nickname.length > MAX_LEN) {
                showFieldError('engines-edit-nickname-err', 'Max ' + MAX_LEN + ' characters.');
                valid = false;
            }

            if (!envVar) {
                showFieldError('engines-edit-env-var-err', 'Env var name is required.');
                valid = false;
            } else if (!ENV_VAR_RE.test(envVar)) {
                showFieldError('engines-edit-env-var-err', 'Must match ^[A-Z][A-Z0-9_]*$ (e.g. ANTHROPIC_API_KEY_DARREN).');
                valid = false;
            }

            if (!valid) return;

            var saveBtn = document.getElementById('engines-edit-save-btn');
            saveBtn.disabled = true;
            saveBtn.textContent = 'SAVING...';

            try {
                var resp = await fetch(
                    ENGINES_API + '/' + encodeURIComponent(_activeEngineSlug) +
                    '/accounts/' + encodeURIComponent(_activeAccountSlug),
                    {
                        method: 'PUT',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({ account_id: accountId, nickname: nickname, env_var_name: envVar })
                    }
                );
                var data = await resp.json();

                if (!resp.ok) {
                    showServerError('engines-edit-server-err', data.error || 'Server error (' + resp.status + ')');
                    return;
                }

                // Non-empty secret == replace/re-seal. Empty == leave existing sealed
                // secret untouched. Use upsert (PUT, fall back to POST on 404) so this
                // works whether or not a secret already exists. XACA-0538-001.
                if (secret) {
                    var sealedOk = await sealAndStoreSecret(
                        _activeEngineSlug, _activeAccountSlug, secret, 'UPSERT', 'engines-edit-secret-err'
                    );
                    secret = '';
                    if (secretEl) secretEl.value = '';
                    if (!sealedOk) {
                        await LCARS_ENGINES.loadEngines();
                        return;
                    }
                }

                hideModal('engines-edit-modal');
                await LCARS_ENGINES.loadEngines();

            } catch (err) {
                console.error('[ENGINES] submitEditAccount error:', err);
                showServerError('engines-edit-server-err', 'Network error: ' + err.message);
            } finally {
                secret = '';
                if (secretEl) secretEl.value = '';
                saveBtn.disabled = false;
                saveBtn.textContent = 'SAVE';
            }
        },

        // =====================================================================
        // SUBMIT — DELETE
        // =====================================================================

        async submitDeleteAccount() {
            var confirmBtn  = document.getElementById('engines-delete-confirm-btn');
            var serverErrEl = document.getElementById('engines-delete-server-err');

            confirmBtn.disabled = true;
            confirmBtn.textContent = 'DELETING...';
            serverErrEl.style.display = 'none';

            try {
                var resp = await fetch(
                    ENGINES_API + '/' + encodeURIComponent(_activeEngineSlug) +
                    '/accounts/' + encodeURIComponent(_activeAccountSlug) + '?confirm=true',
                    { method: 'DELETE' }
                );
                var data = await resp.json();

                if (!resp.ok) {
                    serverErrEl.textContent = data.error || 'Server error (' + resp.status + ')';
                    serverErrEl.style.display = 'block';
                    return;
                }

                hideModal('engines-delete-modal');
                await LCARS_ENGINES.loadEngines();

            } catch (err) {
                console.error('[ENGINES] submitDeleteAccount error:', err);
                serverErrEl.textContent = 'Network error: ' + err.message;
                serverErrEl.style.display = 'block';
            } finally {
                confirmBtn.disabled = false;
                confirmBtn.textContent = 'CONFIRM DELETE';
            }
        }
    };

    // =========================================================================
    // PRIVATE HELPERS
    // =========================================================================

    function escHtml(str) {
        if (str == null) return '';
        return String(str)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&#39;');
    }

    function fmtDate(iso) {
        if (!iso) return '—';
        var d = new Date(iso);
        if (isNaN(d.getTime())) return '—';
        return d.toLocaleDateString() + ' ' + d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    }

    /**
     * Render the vault-provisioned status badge for an account, using the additive
     * read-time fields from /api/engines (has_vault_secret, vault_recipient_count).
     * Read-only display only — no recompute. XACA-0538-006.
     * @param {object} account
     * @returns {string} HTML for the badge cell content
     */
    function vaultBadge(account) {
        if (account && account.has_vault_secret) {
            var n = (typeof account.vault_recipient_count === 'number') ? account.vault_recipient_count : 0;
            var noun = (n === 1) ? 'machine' : 'machines';
            return '<span class="engine-vault-badge engine-vault-badge--provisioned" ' +
                'title="A secret is sealed to ' + n + ' authorized ' + noun + '">' +
                'VAULT: ' + n + ' ' + noun + '</span>';
        }
        return '<span class="engine-vault-badge engine-vault-badge--none" ' +
            'title="No vault secret stored for this account">VAULT: not provisioned</span>';
    }

    function showModal(id) {
        var el = document.getElementById(id);
        if (el) el.classList.add('active');
    }

    function hideModal(id) {
        var el = document.getElementById(id);
        if (el) el.classList.remove('active');
    }

    function showFieldError(errId, msg) {
        var el = document.getElementById(errId);
        if (!el) return;
        el.textContent = msg;
        el.style.display = 'block';
    }

    function showServerError(errId, msg) {
        var el = document.getElementById(errId);
        if (!el) return;
        el.textContent = msg;
        el.style.display = 'block';
    }

    function clearAddErrors() {
        ['engines-add-slug-err', 'engines-add-account-id-err', 'engines-add-nickname-err',
            'engines-add-env-var-err', 'engines-add-secret-err', 'engines-add-server-err'].forEach(function(id) {
            var el = document.getElementById(id);
            if (el) { el.textContent = ''; el.style.display = 'none'; }
        });
    }

    function clearEditErrors() {
        ['engines-edit-account-id-err', 'engines-edit-nickname-err',
            'engines-edit-env-var-err', 'engines-edit-secret-err', 'engines-edit-server-err'].forEach(function(id) {
            var el = document.getElementById(id);
            if (el) { el.textContent = ''; el.style.display = 'none'; }
        });
    }

    // =========================================================================
    // VAULT SECRET SEALING (XACA-0538-001)
    // =========================================================================

    /**
     * Seal a plaintext secret to every registered vault machine and store the
     * resulting ciphertext array. The plaintext is sealed CLIENT-SIDE via
     * window.LCARS_VAULT_SEAL (libsodium crypto_box_seal); only base64 ciphertext
     * leaves the browser. The server never receives or stores plaintext.
     *
     * @param {string} engineSlug
     * @param {string} accountSlug
     * @param {string} secret      plaintext (never logged; caller clears its own ref)
     * @param {'POST'|'PUT'|'UPSERT'} mode  POST=create, PUT=replace, UPSERT=PUT then POST-on-404
     * @param {string} errId       field-error element id to surface failures into
     * @returns {Promise<boolean>} true on success; false (and an error is shown) on failure
     */
    async function sealAndStoreSecret(engineSlug, accountSlug, secret, mode, errId) {
        if (!window.LCARS_VAULT_SEAL) {
            showFieldError(errId, 'Vault crypto library not loaded — cannot seal secret. Reload the page and retry.');
            return false;
        }

        var ciphertexts;
        try {
            // Build the per-machine sealed-box array. Throws on zero machines or a
            // malformed public key (handled below as a field error — never an upload).
            ciphertexts = await window.LCARS_VAULT_SEAL.sealSecret(secret);
        } catch (sealErr) {
            console.error('[ENGINES] seal error:', sealErr);
            showFieldError(errId, sealErr.message || 'Failed to seal secret.');
            return false;
        }

        var base = '/api/vault/secrets';
        var per  = base + '/' + encodeURIComponent(engineSlug) + '/' + encodeURIComponent(accountSlug);

        try {
            var ok;
            if (mode === 'POST') {
                ok = await postSecret(base, engineSlug, accountSlug, ciphertexts, errId);
            } else if (mode === 'PUT') {
                ok = await putSecret(per, ciphertexts, errId);
            } else { // UPSERT: try PUT (re-seal), fall back to POST if it doesn't exist yet.
                var putResp = await fetch(per, {
                    method: 'PUT',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ engine_slug: engineSlug, account_slug: accountSlug, ciphertexts: ciphertexts })
                });
                if (putResp.status === 404) {
                    ok = await postSecret(base, engineSlug, accountSlug, ciphertexts, errId);
                } else {
                    ok = await handleSecretResponse(putResp, errId);
                }
            }
            return ok;
        } catch (netErr) {
            console.error('[ENGINES] store secret error:', netErr);
            showFieldError(errId, 'Network error storing secret: ' + netErr.message);
            return false;
        } finally {
            // Drop the local reference to the sealed bytes too (defensive).
            ciphertexts = null;
        }
    }

    async function postSecret(base, engineSlug, accountSlug, ciphertexts, errId) {
        var resp = await fetch(base, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ engine_slug: engineSlug, account_slug: accountSlug, ciphertexts: ciphertexts })
        });
        if (resp.status === 409) {
            showFieldError(errId, 'A vault secret already exists for this account — use EDIT to replace it.');
            return false;
        }
        return handleSecretResponse(resp, errId);
    }

    async function putSecret(per, ciphertexts, errId) {
        var resp = await fetch(per, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ ciphertexts: ciphertexts })
        });
        return handleSecretResponse(resp, errId);
    }

    /**
     * Surface a structured vault API response. Renders 400 validation `details`,
     * 404, and other errors into the given field-error element.
     * @returns {Promise<boolean>} true if 2xx
     */
    async function handleSecretResponse(resp, errId) {
        if (resp.ok) return true;
        var body = null;
        try { body = await resp.json(); } catch (_) { /* non-JSON */ }
        var msg = (body && body.error) ? body.error : ('Server error (' + resp.status + ')');
        if (body && Array.isArray(body.details) && body.details.length) {
            msg += ': ' + body.details.join('; ');
        } else if (body && body.message) {
            msg += ' — ' + body.message;
        }
        showFieldError(errId, msg);
        return false;
    }

    // =========================================================================
    // INITIALIZATION
    // =========================================================================

    function init() {
        if (_initialized) return;
        _initialized = true;

        console.log('[ENGINES] Initializing AI Engines UI (XACA-0281)...');

        // Wire REFRESH button
        var refreshBtn = document.getElementById('engines-refresh-btn');
        if (refreshBtn) {
            refreshBtn.addEventListener('click', function() {
                LCARS_ENGINES.loadEngines();
            });
        }

        // Wire ADD modal buttons
        var addSave   = document.getElementById('engines-add-save-btn');
        var addCancel = document.getElementById('engines-add-cancel-btn');
        if (addSave)   addSave.addEventListener('click',   function() { LCARS_ENGINES.submitAddAccount(); });
        if (addCancel) addCancel.addEventListener('click', function() { hideModal('engines-add-modal'); });

        // Wire EDIT modal buttons
        var editSave   = document.getElementById('engines-edit-save-btn');
        var editCancel = document.getElementById('engines-edit-cancel-btn');
        if (editSave)   editSave.addEventListener('click',   function() { LCARS_ENGINES.submitEditAccount(); });
        if (editCancel) editCancel.addEventListener('click', function() { hideModal('engines-edit-modal'); });

        // Wire DELETE modal buttons
        var delConfirm = document.getElementById('engines-delete-confirm-btn');
        var delCancel  = document.getElementById('engines-delete-cancel-btn');
        if (delConfirm) delConfirm.addEventListener('click', function() { LCARS_ENGINES.submitDeleteAccount(); });
        if (delCancel)  delCancel.addEventListener('click',  function() { hideModal('engines-delete-modal'); });

        // Close any engines modal on backdrop click
        document.querySelectorAll('.engines-modal').forEach(function(overlay) {
            overlay.addEventListener('click', function(e) {
                if (e.target === overlay) {
                    overlay.classList.remove('active');
                }
            });
        });

        // Close modals on Escape key
        document.addEventListener('keydown', function(e) {
            if (e.key === 'Escape') {
                document.querySelectorAll('.engines-modal.active').forEach(function(m) {
                    m.classList.remove('active');
                });
            }
        });

        // Load data when the ENGINES section is activated
        document.addEventListener('lcars:sectionChange', function(e) {
            if (e.detail && e.detail.section === 'engines') {
                LCARS_ENGINES.loadEngines();
            }
        });

        // If already on engines section at page load, fetch now
        var activeSection = document.querySelector('.lcars-section.active[data-section="engines"]');
        if (activeSection) {
            LCARS_ENGINES.loadEngines();
        }

        console.log('[ENGINES] AI Engines UI ready.');
    }

    // Expose globally so console debugging works
    window.LCARS_ENGINES = LCARS_ENGINES;

    // Boot after DOM is ready
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }

})();

// === /XACA-0281 ===
