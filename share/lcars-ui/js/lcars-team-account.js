/**
 * lcars-team-account.js
 * XACA-0281-022 — Per-team AI engine account picker dropdown
 * XACA-0281-007 — Running-sessions warning modal (pre-assign guard)
 * XACA-0281-008 — Resume-ID handling modal (post-assign cleanup)
 *
 * DEFAULT path: dropdown loaded from /api/engines/list (populated from Fleet Monitor registry).
 * FALLBACK path: "MANUAL" button opens the existing edit modal (Wave 1, XACA-0281-002).
 *
 * Depends on: lcars.js (apiUrl, showToast, CONFIG), loaded BEFORE this file.
 * Does NOT modify lcars.js — hooks into loadTeamConfig() by augmenting the call
 * site via window.lcarsTeamAccount global + the lcars:section-shown event pattern.
 */

(function (global) {
    'use strict';

    // ─────────────────────────────────────────────────────────────
    // Fleet Monitor URL discovery
    //
    // Canonical path: same-hostname heuristic on port 8080.
    // The meta-tag approach was removed (XACA-0281-027) because serve_file()
    // does not template HTML, so {{FLEET_MONITOR_URL}} was never substituted.
    // TODO XACA-0281 follow-up: dynamic Fleet Monitor URL discovery.
    // ─────────────────────────────────────────────────────────────
    function getFleetMonitorUrl() {
        // Heuristic: assume Fleet Monitor runs on port 8080 of the same host.
        // TODO XACA-0281 follow-up: dynamic Fleet Monitor URL discovery.
        return window.location.protocol + '//' + window.location.hostname + ':8080';
    }

    // ─────────────────────────────────────────────────────────────
    // Module-level cache (per page load; invalidated on demand)
    // ─────────────────────────────────────────────────────────────
    var _enginesCache = null;   // { version, engines: [...] }

    // ─────────────────────────────────────────────────────────────
    // XACA-0281-007: Pending-assign/save state
    //
    // When the running-sessions modal intercepts a picker change or
    // manual save, we park the pending operation here so the modal
    // confirm buttons can fire it without re-fetching everything.
    // Only one pending operation can exist at a time (one modal).
    // ─────────────────────────────────────────────────────────────
    var _pendingAssign = null;  // { teamSlug, engineSlug, accountSlug, oldAccountId, selectEl }
    var _pendingSave   = null;  // { teamSlug, payload, oldAccountId, saveBtn, testStatusEl }

    // ─────────────────────────────────────────────────────────────
    // XACA-0281-008: Pending resume-ids state
    //
    // After a successful assign/save, if orphaned resume IDs exist
    // on the old account, we park the context here for the resume
    // modal's Apply button to reference.
    // ─────────────────────────────────────────────────────────────
    var _pendingResumeIds = null; // { teamSlug, oldAccountId }

    // ─────────────────────────────────────────────────────────────
    // loadTeamAccountList()
    //
    // Called when the team-config section becomes active.
    // 1. Fetches engines list once (caches for session).
    // 2. Reads team list from the existing #team-account-list DOM or
    //    falls back to CONFIG.team (single-team boards).
    // 3. Fetches per-team current account config.
    // 4. Renders a row per team using the row template.
    // ─────────────────────────────────────────────────────────────
    async function loadTeamAccountList() {
        var listEl = document.getElementById('team-account-list');
        if (!listEl) return;

        // Show a transient loading state.
        listEl.innerHTML = '<div class="team-account-loading">Loading account registry…</div>';

        try {
            var engines = await _fetchEngines();
        } catch (err) {
            listEl.innerHTML = '<div class="team-account-loading team-account-error">Failed to load account registry: ' + _escHtml(err.message) + '</div>';
            console.error('[team-account] loadTeamAccountList engines error:', err);
            return;
        }

        // Derive team list: ask the server for all teams in team-paths.json.
        // Endpoint /api/team-config/account/list is not yet implemented, so we
        // fall back to CONFIG.team (the current board's team). If the server
        // later ships that endpoint, just swap the block below.
        var teams;
        try {
            var r = await fetch(_apiUrl('/api/team-config/account/list'));
            if (r.ok) {
                var payload = await r.json();
                teams = Array.isArray(payload.teams) ? payload.teams : null;
            }
        } catch (_) { /* optional endpoint — ignore */ }

        if (!teams || teams.length === 0) {
            // Graceful fallback: render only the current board's team.
            var currentTeam = (typeof CONFIG !== 'undefined' && CONFIG.team) ? CONFIG.team : null;
            teams = currentTeam ? [currentTeam] : [];
        }

        if (teams.length === 0) {
            listEl.innerHTML = '<div class="team-account-loading">No teams configured. Check ~/.aiteamforge/team-paths.json.</div>';
            return;
        }

        // Fetch current config per team, then render rows.
        listEl.innerHTML = '';
        var fetchPromises = teams.map(function (teamSlug) {
            return _fetchCurrentConfig(teamSlug)
                .then(function (cfg) {
                    return { teamSlug: teamSlug, cfg: cfg };
                })
                .catch(function (err) {
                    console.warn('[team-account] failed to load config for team', teamSlug, err);
                    return { teamSlug: teamSlug, cfg: null };
                });
        });

        var results = await Promise.all(fetchPromises);
        results.forEach(function (r) {
            var rowEl = renderTeamRow(r.teamSlug, r.cfg, engines);
            if (rowEl) listEl.appendChild(rowEl);
        });
    }

    // ─────────────────────────────────────────────────────────────
    // renderTeamRow(teamSlug, currentConfig, engines)
    //
    // Clones #team-account-row-template, fills the dropdown from engines,
    // sets status dot, wires the picker + MANUAL button.
    // Returns the cloned Element or null if template missing.
    // ─────────────────────────────────────────────────────────────
    function renderTeamRow(teamSlug, currentConfig, engines) {
        var tmpl = document.getElementById('team-account-row-template');
        if (!tmpl) return null;

        var row = tmpl.content.cloneNode(true).firstElementChild;

        // Set team data attributes.
        row.dataset.team = teamSlug;

        // Determine credential status.
        var status = _resolveCredentialStatus(currentConfig);
        row.dataset.credentialStatus = status;

        // Tooltip on the status dot so the color isn't a mystery.
        var dotEl = row.querySelector('.team-account-status-dot');
        if (dotEl) {
            dotEl.title = (
                status === 'ok' ? 'Credentials present and validated' :
                status === 'missing' ? 'No credentials — env var not set in this LCARS process' :
                'Credentials present but never validated — run TEST CONNECTION'
            );
        }

        // Fill left-side labels.
        var nameEl = row.querySelector('.team-account-team-name');
        if (nameEl) nameEl.textContent = teamSlug.toUpperCase();

        var acctIdEl = row.querySelector('.team-account-account-id');
        if (acctIdEl) {
            var rawId = (currentConfig && currentConfig.account_id) ? currentConfig.account_id : '';
            acctIdEl.textContent = rawId ? rawId.slice(0, 12) + '…' : '(default OAuth)';
        }

        var nickEl = row.querySelector('.team-account-nickname');
        if (nickEl) {
            nickEl.textContent = (currentConfig && currentConfig.account_nickname)
                ? currentConfig.account_nickname
                : 'not set';
        }

        // Build the right-side cell: inject picker + demote the EDIT button.
        var rightEl = row.querySelector('.team-config-row-right');
        if (rightEl) {
            // Inject dropdown BEFORE the status dot.
            var picker = _buildPickerSelect(teamSlug, currentConfig, engines);
            // Insert picker as the first child of the right cell.
            rightEl.insertBefore(picker, rightEl.firstChild);

            // Rename the existing EDIT button to MANUAL and add a deprecated look.
            var editBtn = row.querySelector('.team-account-edit-btn');
            if (editBtn) {
                editBtn.textContent = 'MANUAL';
                editBtn.classList.add('team-account-manual-btn');
                editBtn.dataset.team = teamSlug;
            }
        }

        return row;
    }

    // ─────────────────────────────────────────────────────────────
    // _buildPickerSelect(teamSlug, currentConfig, engines)
    //
    // Returns a <select class="team-account-picker"> element.
    // ─────────────────────────────────────────────────────────────
    function _buildPickerSelect(teamSlug, currentConfig, engines) {
        var sel = document.createElement('select');
        sel.className = 'team-account-picker';
        sel.setAttribute('aria-label', 'Select AI engine account for ' + teamSlug);

        // Determine the currently selected value so we can mark it as selected.
        // Match by account_id from currentConfig — we look for engine/account that
        // has a matching account_id field.
        var currentAccountId = currentConfig ? (currentConfig.account_id || '') : '';

        // Blank/default option.
        var blankOpt = document.createElement('option');
        blankOpt.value = '';
        blankOpt.textContent = '— default OAuth —';
        if (!currentAccountId) blankOpt.selected = true;
        sel.appendChild(blankOpt);

        var engineList = (engines && Array.isArray(engines.engines)) ? engines.engines : [];

        engineList.forEach(function (engine) {
            var grp = document.createElement('optgroup');
            grp.label = engine.name || engine.slug || 'Unknown Engine';

            var accounts = Array.isArray(engine.accounts) ? engine.accounts : [];
            accounts.forEach(function (acct) {
                var opt = document.createElement('option');
                var val = engine.slug + '/' + acct.slug;
                opt.value = val;

                // Label: "Nickname (acct_01JXXXXXXXX…)"
                var label = acct.nickname || acct.slug;
                if (acct.account_id) {
                    label += ' (' + acct.account_id.slice(0, 12) + '…)';
                }
                opt.textContent = label;

                // Mark as selected if this matches the current config's account_id.
                if (currentAccountId && acct.account_id && acct.account_id === currentAccountId) {
                    opt.selected = true;
                    // Deselect the blank option.
                    blankOpt.selected = false;
                }

                grp.appendChild(opt);
            });

            // "+ ADD NEW" sentinel at the bottom of each engine's optgroup.
            var addNewOpt = document.createElement('option');
            addNewOpt.value = '__add_new__/' + engine.slug;
            addNewOpt.textContent = '+ ADD NEW (' + (engine.name || engine.slug) + ')';
            grp.appendChild(addNewOpt);

            sel.appendChild(grp);
        });

        // Wire change handler.
        sel.addEventListener('change', function () {
            onAccountPickerChange(teamSlug, sel.value, sel);
        });

        return sel;
    }

    // ─────────────────────────────────────────────────────────────
    // onAccountPickerChange(teamSlug, value, selectEl)
    //
    // Handles picker selection:
    //   "__add_new__/<engineSlug>" → toast with Fleet Monitor URL
    //   ""                         → no-op (user chose default OAuth; they
    //                                should use MANUAL to clear the mapping)
    //   "<engineSlug>/<accountSlug>" → pre-assign running-sessions check
    //                                  (XACA-0281-007), then POST assign,
    //                                  then post-assign resume-ids check
    //                                  (XACA-0281-008)
    // ─────────────────────────────────────────────────────────────
    async function onAccountPickerChange(teamSlug, value, selectEl) {
        if (!value) return;

        // "+ ADD NEW" sentinel.
        if (value.startsWith('__add_new__/')) {
            var engineSlug = value.slice('__add_new__/'.length);
            var fleetUrl = getFleetMonitorUrl();
            // Show a non-blocking toast with a clickable URL rather than a
            // blocking alert(), so it fits the LCARS UX pattern.
            _showToast(
                'Add accounts in Fleet Monitor: ' + fleetUrl +
                    ' — navigate to AI ENGINES → ' + engineSlug.toUpperCase() + ' → Add Account',
                'info',
                8000
            );
            // Reset the picker by re-rendering the full row from current config.
            _refreshTeamRow(teamSlug).catch(function () {});
            return;
        }

        // Split "<engineSlug>/<accountSlug>".
        var slash = value.indexOf('/');
        if (slash === -1) return;
        var engineSlug = value.slice(0, slash);
        var accountSlug = value.slice(slash + 1);

        // Resolve the new account_id from the engines cache so we can check
        // whether the account is actually changing (skip the modal if same).
        var newAccountId = null;
        try {
            var engines = await _fetchEngines();
            var engineList = (engines && Array.isArray(engines.engines)) ? engines.engines : [];
            for (var ei = 0; ei < engineList.length; ei++) {
                if (engineList[ei].slug === engineSlug) {
                    var accounts = Array.isArray(engineList[ei].accounts) ? engineList[ei].accounts : [];
                    for (var ai = 0; ai < accounts.length; ai++) {
                        if (accounts[ai].slug === accountSlug) {
                            newAccountId = accounts[ai].account_id || null;
                            break;
                        }
                    }
                    break;
                }
            }
        } catch (_) { /* non-fatal — proceed without comparison */ }

        // Fetch old account_id to compare.
        var oldAccountId = null;
        var oldNickname = null;
        try {
            var oldCfg = await _fetchCurrentConfig(teamSlug);
            oldAccountId = oldCfg ? (oldCfg.account_id || null) : null;
            oldNickname = oldCfg ? (oldCfg.account_nickname || oldAccountId || 'previous account') : 'previous account';
        } catch (_) { /* non-fatal */ }

        // XACA-0281-007: Pre-assign running-sessions guard.
        // Only show the modal when the account is actually changing.
        var accountChanging = (newAccountId !== oldAccountId);
        if (accountChanging) {
            try {
                var sessResp = await fetch(_apiUrl('/api/team-config/account/running-sessions?team=' + encodeURIComponent(teamSlug)));
                if (sessResp.ok) {
                    var sessData = await sessResp.json();
                    var sessions = Array.isArray(sessData.sessions) ? sessData.sessions : [];
                    if (sessions.length > 0) {
                        // Show warning modal; store continuation closure so the
                        // user's choice can fire _doAssign without re-fetching.
                        _pendingAssign = {
                            teamSlug: teamSlug,
                            engineSlug: engineSlug,
                            accountSlug: accountSlug,
                            oldAccountId: oldAccountId,
                            selectEl: selectEl
                        };
                        openRunningSessionsModal(teamSlug, oldNickname, sessions);
                        // Control returns here; the actual assign fires from
                        // confirmRunningSessionsAndProceed() when the user clicks.
                        return;
                    }
                }
            } catch (err) {
                console.warn('[team-account] running-sessions check failed (proceeding):', err);
            }
        }

        // No sessions conflict (or same account) — assign immediately.
        if (selectEl) selectEl.disabled = true;
        try {
            await _doAssign(teamSlug, engineSlug, accountSlug, oldAccountId, selectEl);
        } finally {
            if (selectEl) selectEl.disabled = false;
        }
    }

    // ─────────────────────────────────────────────────────────────
    // openTeamAccountEditModal(teamSlug)
    //
    // Opens the existing Wave-1 manual-override modal,
    // pre-fills via /api/team-config/account/current.
    // ─────────────────────────────────────────────────────────────
    async function openTeamAccountEditModal(teamSlug) {
        var modal = document.getElementById('team-account-edit-modal');
        if (!modal) return;

        // Clear any previous test status.
        var testStatusEl = document.getElementById('team-account-test-status');
        if (testStatusEl) {
            testStatusEl.textContent = '';
            testStatusEl.className = '';
        }

        // Set hidden team slug field.
        var slugInput = document.getElementById('team-account-edit-team-slug');
        if (slugInput) slugInput.value = teamSlug;

        // Update modal title.
        var titleEl = document.getElementById('team-account-edit-modal-title');
        if (titleEl) titleEl.textContent = 'MANUAL ACCOUNT ROUTING — ' + teamSlug.toUpperCase();

        // Pre-fill fields from current config.
        try {
            var cfg = await _fetchCurrentConfig(teamSlug);
            _fillModalFields(cfg);
        } catch (err) {
            console.warn('[team-account] pre-fill failed for', teamSlug, err);
            _fillModalFields(null);
        }

        modal.style.display = '';
    }

    // ─────────────────────────────────────────────────────────────
    // closeTeamAccountEditModal()
    // ─────────────────────────────────────────────────────────────
    function closeTeamAccountEditModal() {
        var modal = document.getElementById('team-account-edit-modal');
        if (modal) modal.style.display = 'none';
    }

    // ─────────────────────────────────────────────────────────────
    // testTeamAccountConnection()
    //
    // Reads current env_var_name from the modal input and POSTs
    // to /api/team-config/account/test-connection.
    // ─────────────────────────────────────────────────────────────
    async function testTeamAccountConnection() {
        var envVarInput = document.getElementById('team-account-edit-env-var');
        var testStatusEl = document.getElementById('team-account-test-status');
        var testBtn = document.getElementById('team-account-test-btn');

        if (!envVarInput || !testStatusEl) return;

        var envVarName = envVarInput.value.trim();
        if (!envVarName) {
            testStatusEl.textContent = 'Enter an env var name first.';
            testStatusEl.className = 'status-error';
            return;
        }

        testStatusEl.textContent = 'Testing…';
        testStatusEl.className = 'status-testing';
        if (testBtn) testBtn.disabled = true;

        try {
            var resp = await fetch(_apiUrl('/api/team-config/account/test-connection'), {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ env_var_name: envVarName })
            });
            var data = await resp.json();

            if (data.ok) {
                var fingerprint = data.account_fingerprint ? ' — ' + data.account_fingerprint : '';
                testStatusEl.textContent = 'Connection OK' + fingerprint;
                testStatusEl.className = 'status-ok';
            } else {
                testStatusEl.textContent = 'Failed: ' + (data.error || 'Unknown error');
                testStatusEl.className = 'status-error';
            }
        } catch (err) {
            testStatusEl.textContent = 'Request error: ' + err.message;
            testStatusEl.className = 'status-error';
        } finally {
            if (testBtn) testBtn.disabled = false;
        }
    }

    // ─────────────────────────────────────────────────────────────
    // saveTeamAccountConfig()
    //
    // Reads all three fields from the manual-override modal and
    // POSTs to /api/team-config/account/save. Before saving,
    // checks for running sessions on the old account
    // (XACA-0281-007). On success, closes the modal, refreshes
    // the row, then checks for orphaned resume IDs (XACA-0281-008).
    // ─────────────────────────────────────────────────────────────
    async function saveTeamAccountConfig() {
        var slugInput = document.getElementById('team-account-edit-team-slug');
        var acctIdInput = document.getElementById('team-account-edit-account-id');
        var nickInput = document.getElementById('team-account-edit-nickname');
        var envVarInput = document.getElementById('team-account-edit-env-var');
        var saveBtn = document.getElementById('team-account-save-btn');
        var testStatusEl = document.getElementById('team-account-test-status');

        if (!slugInput) return;
        var teamSlug = slugInput.value.trim();
        if (!teamSlug) return;

        var newAccountId = acctIdInput ? acctIdInput.value.trim() : '';

        var payload = {
            team: teamSlug,
            account_id: newAccountId,
            account_nickname: nickInput ? nickInput.value.trim() : '',
            env_var_name: envVarInput ? envVarInput.value.trim() : ''
        };

        // XACA-0281-007: Pre-save running-sessions guard.
        // Fetch current config to determine if account is changing.
        var oldAccountId = null;
        var oldNickname = 'previous account';
        try {
            var oldCfg = await _fetchCurrentConfig(teamSlug);
            oldAccountId = oldCfg ? (oldCfg.account_id || null) : null;
            oldNickname = oldCfg ? (oldCfg.account_nickname || oldAccountId || 'previous account') : 'previous account';
        } catch (_) { /* non-fatal */ }

        var accountChanging = (newAccountId !== (oldAccountId || ''));
        if (accountChanging) {
            try {
                var sessResp = await fetch(_apiUrl('/api/team-config/account/running-sessions?team=' + encodeURIComponent(teamSlug)));
                if (sessResp.ok) {
                    var sessData = await sessResp.json();
                    var sessions = Array.isArray(sessData.sessions) ? sessData.sessions : [];
                    if (sessions.length > 0) {
                        // Store pending save payload; user will confirm via modal button.
                        _pendingSave = {
                            teamSlug: teamSlug,
                            payload: payload,
                            oldAccountId: oldAccountId,
                            saveBtn: saveBtn,
                            testStatusEl: testStatusEl
                        };
                        openRunningSessionsModal(teamSlug, oldNickname, sessions);
                        return; // Actual save deferred to confirmRunningSessionsAndProceed()
                    }
                }
            } catch (err) {
                console.warn('[team-account] running-sessions check (save) failed (proceeding):', err);
            }
        }

        // No conflict or same account — proceed immediately.
        await _doSave(teamSlug, payload, oldAccountId, saveBtn, testStatusEl);
    }

    // ─────────────────────────────────────────────────────────────
    // XACA-0281-007: Running-sessions modal
    // ─────────────────────────────────────────────────────────────

    /**
     * openRunningSessionsModal(teamSlug, oldNickname, sessions)
     *
     * Populates and displays #team-account-running-sessions-modal.
     * sessions: [{pid, terminal, started_at, cwd}]
     */
    function openRunningSessionsModal(teamSlug, oldNickname, sessions) {
        var modal = document.getElementById('team-account-running-sessions-modal');
        if (!modal) return;

        var summaryEl = document.getElementById('team-account-sessions-summary');
        if (summaryEl) {
            summaryEl.textContent =
                sessions.length + ' session' + (sessions.length === 1 ? '' : 's') +
                ' for ' + teamSlug.toUpperCase() +
                ' ' + (sessions.length === 1 ? 'is' : 'are') +
                ' running on the old account (“' + _escHtml(String(oldNickname)) + '”).' +
                ' They will continue using that account until they exit.';
        }

        var listEl = document.getElementById('team-account-sessions-list');
        if (listEl) {
            listEl.innerHTML = '';
            sessions.forEach(function (sess) {
                var item = document.createElement('div');
                item.className = 'team-account-session-item';

                var startedAt = sess.started_at ? _relativeTime(sess.started_at) : 'unknown';
                var cwd = (sess.cwd || '').replace(/^\/Users\/[^/]+/, '~');
                // Truncate long cwd paths to keep the modal tidy.
                if (cwd.length > 55) cwd = cwd.slice(0, 52) + '…';

                item.innerHTML =
                    '<span class="session-pid">PID ' + _escHtml(String(sess.pid || '?')) + '</span>' +
                    '<span class="session-terminal">' + _escHtml(String(sess.terminal || '?')) + '</span>' +
                    '<span class="session-cwd" title="' + _escHtml(String(sess.cwd || '')) + '">' + _escHtml(cwd) + '</span>' +
                    '<span class="session-started">' + _escHtml(startedAt) + '</span>';

                listEl.appendChild(item);
            });
        }

        modal.style.display = '';
    }

    /** closeRunningSessionsModal() — cancels pending operation and hides modal. */
    function closeRunningSessionsModal() {
        _pendingAssign = null;
        _pendingSave   = null;
        var modal = document.getElementById('team-account-running-sessions-modal');
        if (modal) modal.style.display = 'none';
    }

    /**
     * confirmRunningSessionsAndProceed(mode)
     *
     * Called by the "Save Anyway" and "Save and Notify" buttons.
     * mode: 'anyway' | 'notify'
     *
     * TODO XACA-0281 followup: 'notify' mode should fire a desktop notification
     * to running sessions (e.g. osascript or WebSocket push). For now both modes
     * proceed identically — the distinction is a placeholder for the notification
     * mechanism.
     */
    async function confirmRunningSessionsAndProceed(mode) {
        var modal = document.getElementById('team-account-running-sessions-modal');
        if (modal) modal.style.display = 'none';

        if (_pendingAssign) {
            var pa = _pendingAssign;
            _pendingAssign = null;
            var selectEl = pa.selectEl;
            if (selectEl) selectEl.disabled = true;
            try {
                await _doAssign(pa.teamSlug, pa.engineSlug, pa.accountSlug, pa.oldAccountId, selectEl);
            } finally {
                if (selectEl) selectEl.disabled = false;
            }
        } else if (_pendingSave) {
            var ps = _pendingSave;
            _pendingSave = null;
            await _doSave(ps.teamSlug, ps.payload, ps.oldAccountId, ps.saveBtn, ps.testStatusEl);
        }
    }

    // ─────────────────────────────────────────────────────────────
    // XACA-0281-008: Resume-IDs modal
    // ─────────────────────────────────────────────────────────────

    /**
     * _checkResumeIds(teamSlug, oldAccountId)
     *
     * Called after a successful account swap. If the old account has
     * orphaned resume points, opens the resume-IDs modal.
     * Silently skips if oldAccountId is null/empty.
     */
    async function _checkResumeIds(teamSlug, oldAccountId) {
        if (!oldAccountId) return;

        try {
            var url = _apiUrl(
                '/api/team-config/account/resume-ids/count?team=' +
                encodeURIComponent(teamSlug) +
                '&old_account_id=' + encodeURIComponent(oldAccountId)
            );
            var resp = await fetch(url);
            if (!resp.ok) return;
            var data = await resp.json();
            var count = data && typeof data.count === 'number' ? data.count : 0;
            if (count > 0) {
                openResumeIdsModal(teamSlug, oldAccountId, count);
            }
        } catch (err) {
            console.warn('[team-account] resume-ids count check failed:', err);
        }
    }

    /**
     * openResumeIdsModal(teamSlug, oldAccountId, count)
     *
     * Populates and shows #team-account-resume-ids-modal.
     */
    function openResumeIdsModal(teamSlug, oldAccountId, count) {
        var modal = document.getElementById('team-account-resume-ids-modal');
        if (!modal) return;

        _pendingResumeIds = { teamSlug: teamSlug, oldAccountId: oldAccountId };

        var summaryEl = document.getElementById('team-account-resume-ids-summary');
        if (summaryEl) {
            summaryEl.textContent =
                'You have ' + count + ' saved resume point' + (count === 1 ? '' : 's') +
                ' for ' + teamSlug.toUpperCase() +
                ' on the old account (“' + _escHtml(String(oldAccountId).slice(0, 12)) + '…”).';
        }

        // Reset radio to default (preserve).
        var preserveRadio = document.getElementById('resume-action-preserve');
        if (preserveRadio) preserveRadio.checked = true;

        modal.style.display = '';
    }

    /** closeResumeIdsModal() — cancels pending resume-ids operation and hides modal. */
    function closeResumeIdsModal() {
        _pendingResumeIds = null;
        var modal = document.getElementById('team-account-resume-ids-modal');
        if (modal) modal.style.display = 'none';
    }

    /**
     * applyResumeIdsAction()
     *
     * Reads the selected radio option and POSTs to
     * /api/team-config/account/resume-ids with the chosen action.
     */
    async function applyResumeIdsAction() {
        if (!_pendingResumeIds) return;

        var applyBtn = document.getElementById('team-account-resume-ids-apply-btn');
        var selected = document.querySelector('input[name="resume-id-action"]:checked');
        var action = selected ? selected.value : 'preserve';

        var ctx = _pendingResumeIds;
        _pendingResumeIds = null;

        var modal = document.getElementById('team-account-resume-ids-modal');
        if (modal) modal.style.display = 'none';

        if (applyBtn) applyBtn.disabled = true;

        try {
            var resp = await fetch(_apiUrl('/api/team-config/account/resume-ids'), {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    team: ctx.teamSlug,
                    old_account_id: ctx.oldAccountId,
                    action: action
                })
            });

            var data = await resp.json();

            if (!resp.ok || !data.success) {
                throw new Error(data.error || ('HTTP ' + resp.status));
            }

            var msg;
            if (action === 'preserve') {
                msg = 'Resume points preserved under old account.';
            } else if (action === 'archive') {
                msg = 'Resume points archived' + (data.archive_path ? ' to ' + data.archive_path : '') + '.';
            } else {
                msg = data.affected + ' resume point' + (data.affected === 1 ? '' : 's') + ' cleared.';
            }

            _showToast(msg, action === 'clear' ? 'warning' : 'success');
        } catch (err) {
            console.error('[team-account] resume-ids action failed:', err);
            _showToast('Failed to apply resume-IDs action: ' + err.message, 'error');
        } finally {
            if (applyBtn) applyBtn.disabled = false;
        }
    }

    // ─────────────────────────────────────────────────────────────
    // _doAssign() — shared assign implementation called by both
    // onAccountPickerChange (direct path) and
    // confirmRunningSessionsAndProceed (deferred path).
    // ─────────────────────────────────────────────────────────────
    async function _doAssign(teamSlug, engineSlug, accountSlug, oldAccountId, selectEl) {
        try {
            var resp = await fetch(_apiUrl('/api/team-config/account/assign'), {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    team: teamSlug,
                    engine_slug: engineSlug,
                    account_slug: accountSlug
                })
            });

            var data = await resp.json();

            if (!resp.ok || !data.success) {
                throw new Error(data.error || ('HTTP ' + resp.status));
            }

            // Refresh the row to reflect new state (nickname, account_id, status dot).
            await _refreshTeamRow(teamSlug);

            var credLabel = data.has_credentials
                ? 'Key env var detected.'
                : 'No key env var set — update ~/.zshrc.secrets.';
            _showToast(
                teamSlug.toUpperCase() + ' → ' + accountSlug + ' assigned. ' + credLabel,
                data.has_credentials ? 'success' : 'warning'
            );

            // XACA-0281-008: Post-assign resume-IDs check.
            await _checkResumeIds(teamSlug, oldAccountId);
        } catch (err) {
            console.error('[team-account] assign failed:', err);
            _showToast('Failed to assign account for ' + teamSlug + ': ' + err.message, 'error');
            // Re-render the row to restore the picker to its current persisted value.
            _refreshTeamRow(teamSlug).catch(function () {});
        }
    }

    // ─────────────────────────────────────────────────────────────
    // _doSave() — shared save implementation called by both
    // saveTeamAccountConfig (direct path) and
    // confirmRunningSessionsAndProceed (deferred path).
    // ─────────────────────────────────────────────────────────────
    async function _doSave(teamSlug, payload, oldAccountId, saveBtn, testStatusEl) {
        if (saveBtn) saveBtn.disabled = true;
        if (testStatusEl) {
            testStatusEl.textContent = 'Saving…';
            testStatusEl.className = 'status-testing';
        }

        try {
            var resp = await fetch(_apiUrl('/api/team-config/account/save'), {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payload)
            });
            var data = await resp.json();

            if (!resp.ok || !data.success) {
                throw new Error(data.error || ('HTTP ' + resp.status));
            }

            closeTeamAccountEditModal();
            await _refreshTeamRow(teamSlug);
            _showToast('Account config saved for ' + teamSlug.toUpperCase(), 'success');

            // XACA-0281-008: Post-save resume-IDs check.
            await _checkResumeIds(teamSlug, oldAccountId);
        } catch (err) {
            console.error('[team-account] save failed:', err);
            if (testStatusEl) {
                testStatusEl.textContent = 'Save failed: ' + err.message;
                testStatusEl.className = 'status-error';
            }
        } finally {
            if (saveBtn) saveBtn.disabled = false;
        }
    }

    // ─────────────────────────────────────────────────────────────
    // Private helpers
    // ─────────────────────────────────────────────────────────────

    /** Fetch and cache the engines list for this page load. */
    async function _fetchEngines(forceRefresh) {
        if (!forceRefresh && _enginesCache) return _enginesCache;
        var url = _apiUrl('/api/engines/list');
        if (forceRefresh) url += (url.includes('?') ? '&' : '?') + 'refresh=true';
        var resp = await fetch(url);
        if (!resp.ok) throw new Error('HTTP ' + resp.status);
        var data = await resp.json();
        _enginesCache = data;
        return data;
    }

    /** Fetch the current account config for one team. */
    async function _fetchCurrentConfig(teamSlug) {
        var resp = await fetch(_apiUrl('/api/team-config/account/current') + '?team=' + encodeURIComponent(teamSlug));
        if (!resp.ok) throw new Error('HTTP ' + resp.status);
        return await resp.json();
    }

    /**
     * Re-render a single team row in-place after a save/assign.
     * Finds the row by data-team, fetches fresh config + engines, replaces element.
     */
    async function _refreshTeamRow(teamSlug) {
        var listEl = document.getElementById('team-account-list');
        if (!listEl) return;

        var existing = listEl.querySelector('.team-account-row[data-team="' + teamSlug + '"]');

        try {
            var engines = await _fetchEngines();
            var cfg = await _fetchCurrentConfig(teamSlug);
            var newRow = renderTeamRow(teamSlug, cfg, engines);
            if (newRow && existing) {
                listEl.replaceChild(newRow, existing);
            } else if (newRow) {
                listEl.appendChild(newRow);
            }
        } catch (err) {
            console.error('[team-account] _refreshTeamRow failed for', teamSlug, err);
        }
    }

    /**
     * Determine credential status from the current config object.
     * Follows the status dot logic from the spec.
     */
    function _resolveCredentialStatus(cfg) {
        if (!cfg || !cfg.has_credentials) return 'missing';
        if (!cfg.last_validated_at) return 'unvalidated';
        var age = Date.now() - new Date(cfg.last_validated_at).getTime();
        var sevenDaysMs = 7 * 24 * 60 * 60 * 1000;
        return age <= sevenDaysMs ? 'ok' : 'unvalidated';
    }

    /** Fill the modal input fields from a config object (or clear them). */
    function _fillModalFields(cfg) {
        var acctIdInput = document.getElementById('team-account-edit-account-id');
        var nickInput = document.getElementById('team-account-edit-nickname');
        var envVarInput = document.getElementById('team-account-edit-env-var');

        if (acctIdInput) acctIdInput.value = (cfg && cfg.account_id) ? cfg.account_id : '';
        if (nickInput) nickInput.value = (cfg && cfg.account_nickname) ? cfg.account_nickname : '';
        if (envVarInput) envVarInput.value = (cfg && cfg.env_var_name) ? cfg.env_var_name : '';
    }

    /**
     * Safe apiUrl() wrapper — uses the global from lcars.js if available,
     * falls back to identity (same-origin relative path) for defensive use.
     */
    function _apiUrl(path) {
        if (typeof apiUrl === 'function') return apiUrl(path);
        return path;
    }

    /**
     * Delegate to the global showToast from lcars.js (line ~357).
     * Falls back to console.log if not yet available (shouldn't happen in practice
     * since lcars.js loads before this file).
     */
    function _showToast(message, type, duration) {
        if (typeof showToast === 'function') {
            showToast(message, type || 'info', duration || null);
        } else {
            console.log('[team-account toast]', type, message);
        }
    }

    /** Minimal HTML escape for user-facing error strings. */
    function _escHtml(str) {
        return String(str)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;');
    }

    /**
     * _relativeTime(isoString)
     *
     * Returns a human-readable relative time string like "3 min ago".
     * Used in the running-sessions list.
     */
    function _relativeTime(isoString) {
        if (!isoString) return 'unknown';
        var then = new Date(isoString).getTime();
        if (isNaN(then)) return String(isoString);
        var diffSec = Math.floor((Date.now() - then) / 1000);
        if (diffSec < 0) return 'just now';
        if (diffSec < 60) return diffSec + 's ago';
        var diffMin = Math.floor(diffSec / 60);
        if (diffMin < 60) return diffMin + ' min ago';
        var diffHr = Math.floor(diffMin / 60);
        if (diffHr < 24) return diffHr + 'h ago';
        return Math.floor(diffHr / 24) + 'd ago';
    }

    // ─────────────────────────────────────────────────────────────
    // Expose public API on window so lcars.js call sites and
    // inline onclick= attributes can reach these functions.
    // ─────────────────────────────────────────────────────────────
    global.loadTeamAccountList = loadTeamAccountList;
    global.renderTeamRow = renderTeamRow;
    global.onAccountPickerChange = onAccountPickerChange;
    global.openTeamAccountEditModal = openTeamAccountEditModal;
    global.closeTeamAccountEditModal = closeTeamAccountEditModal;
    global.testTeamAccountConnection = testTeamAccountConnection;
    global.saveTeamAccountConfig = saveTeamAccountConfig;
    // XACA-0281-007: Running-sessions modal
    global.closeRunningSessionsModal = closeRunningSessionsModal;
    global.confirmRunningSessionsAndProceed = confirmRunningSessionsAndProceed;
    // XACA-0281-008: Resume-IDs modal
    global.closeResumeIdsModal = closeResumeIdsModal;
    global.applyResumeIdsAction = applyResumeIdsAction;

    // ─────────────────────────────────────────────────────────────
    // Hook into switchSection('team-config')
    //
    // lcars.js line ~9167 calls `loadTeamConfig()` when the team-config
    // section activates. We don't want to edit lcars.js, so we monkey-patch
    // the global `loadTeamConfig` to also fire `loadTeamAccountList` on each
    // activation.
    //
    // Pattern: wrap after DOMContentLoaded to ensure lcars.js has defined the
    // function first (this file loads synchronously right after lcars.js, so
    // it's safe to patch immediately; we use DOMContentLoaded as a belt+braces
    // guard for deferred-parse environments).
    // ─────────────────────────────────────────────────────────────
    function _patchLoadTeamConfig() {
        var _original = global.loadTeamConfig;
        if (typeof _original !== 'function') {
            // lcars.js not yet parsed (unlikely but safe).
            return;
        }
        global.loadTeamConfig = function () {
            var result = _original.apply(this, arguments);
            // loadTeamAccountList() is async; fire-and-forget alongside loadTeamConfig.
            if (typeof loadTeamAccountList === 'function') {
                loadTeamAccountList().catch(function (err) {
                    console.error('[team-account] loadTeamAccountList error:', err);
                });
            }
            return result;
        };
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', _patchLoadTeamConfig);
    } else {
        _patchLoadTeamConfig();
    }

})(window);
