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
    // XACA-1178-006: the old same-hostname :8080 heuristic (getFleetMonitorUrl(),
    // removed) is gone. The URL is now resolved server-side by
    // _resolve_fleet_monitor_url() in server.py (env var → ~/.aiteamforge/
    // fleet-config.json → ~/.dev-team/fleet-config.json, no localhost fallback)
    // and rides along as _fleet_monitor_url in the /api/engines/list response —
    // see onAccountPickerChange() below, which reads it from _fetchEngines().
    // ─────────────────────────────────────────────────────────────

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
                // XACA-1246-006: _missingCredentialTooltip collapses several
                // distinct states (undeclared, declared-but-unresolvable-
                // with-fault, declared-but-unresolvable-no-reason) — see its
                // own comment for why each is worded differently, and never
                // as "env var not set in this LCARS process" (false for a
                // declared credential resolved through the vault/cache
                // chain, and misleading for the launchd case this ticket
                // exists to fix). Both 'undeclared' and 'missing' route
                // through it — the function itself branches on cfg to pick
                // the right wording; only the DOT's color/shape (CSS,
                // data-credential-status) tells them apart visually.
                (status === 'missing' || status === 'undeclared') ? _missingCredentialTooltip(currentConfig) :
                // XACA-1246 [UX-023]: the validation cache was re-keyed
                // from env_var_name alone to (team, env_var_name) — see
                // _load_account_validation_cache's docstring (server.py).
                // Multiple teams sharing one variable used to inherit
                // whichever of them last ran TEST CONNECTION as a shared,
                // wrong-team green; the re-key makes each team earn its
                // own validation, so a team that was showing green purely
                // off that shared entry flips to this state with no
                // action having actually changed. Said explicitly so that
                // flip doesn't read as a fresh regression -- proportionate
                // one-line addendum, not a dismissible banner/framework.
                'Credentials present but not yet validated under this team\'s own record — run ' +
                'TEST CONNECTION. (If this was green before recent maintenance, that is expected: ' +
                'a validation-cache correctness fix reset entries that used to be shared between ' +
                'teams declaring the same variable.)'
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
            // XACA-1178-006: read the server-resolved URL from the /api/engines/list
            // response instead of guessing "<page-host>:8080" (E12) — that guess is
            // wrong whenever Fleet Monitor isn't colocated with LCARS, which is the
            // normal case (the real base is a remote fleet-monitor.fly.dev host).
            var fleetUrl = null;
            try {
                var enginesForUrl = await _fetchEngines();
                fleetUrl = enginesForUrl && enginesForUrl._fleet_monitor_url;
            } catch (_) { /* non-fatal — falls through to the "not configured" toast */ }
            // Show a non-blocking toast with a clickable URL rather than a
            // blocking alert(), so it fits the LCARS UX pattern.
            if (fleetUrl) {
                _showToast(
                    'Add accounts in Fleet Monitor: ' + fleetUrl +
                        ' — navigate to AI ENGINES → ' + engineSlug.toUpperCase() + ' → Add Account',
                    'info',
                    8000
                );
            } else {
                _showToast(
                    'Fleet Monitor URL not configured — set FLEET_MONITOR_URL or ' +
                        '~/.aiteamforge/fleet-config.json to add accounts.',
                    'warning',
                    8000
                );
            }
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
    //
    // XACA-1246 [Review] finding (highest severity): this used to post
    // ONLY env_var_name, never the team the modal is actually editing —
    // the server then had to GUESS which team's credential to resolve
    // (try its own LCARS_TEAM, else scan team-paths.json for the first
    // team declaring the same var name). Every declared team currently
    // names the same variable (CLAUDE_ACCT_ME_TOKEN for academy/android/
    // command), so testing one team's credential could silently resolve
    // and probe a DIFFERENT team's token and record last_validated_at
    // against the wrong one. The modal already knows which team it's
    // editing (the hidden team-account-edit-team-slug field, set by
    // openTeamAccountEditModal) — send it, so the server never has to
    // guess.
    // ─────────────────────────────────────────────────────────────
    async function testTeamAccountConnection() {
        var envVarInput = document.getElementById('team-account-edit-env-var');
        var testStatusEl = document.getElementById('team-account-test-status');
        var testBtn = document.getElementById('team-account-test-btn');
        var slugInput = document.getElementById('team-account-edit-team-slug');

        if (!envVarInput || !testStatusEl) return;

        var envVarName = envVarInput.value.trim();
        var teamSlug = slugInput ? slugInput.value.trim() : '';
        if (!envVarName) {
            testStatusEl.textContent = 'Enter an env var name first.';
            testStatusEl.className = 'status-error';
            return;
        }

        testStatusEl.textContent = 'Testing…';
        testStatusEl.className = 'status-testing';
        if (testBtn) testBtn.disabled = true;

        try {
            var testBody = { env_var_name: envVarName };
            // Only include `team` when the modal actually has one — an
            // unsaved candidate value with no associated team is still a
            // legitimate (if narrower) case the server must fail
            // explicitly on, not guess through.
            if (teamSlug) testBody.team = teamSlug;
            var resp = await apiFetch(_apiUrl('/api/team-config/account/test-connection'), {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(testBody)
            });
            var data = await resp.json();

            if (data.ok) {
                var fingerprint = data.account_fingerprint ? ' — ' + data.account_fingerprint : '';
                testStatusEl.textContent = 'Connection OK' + fingerprint;
                testStatusEl.className = 'status-ok';
            } else if (data.probed === false) {
                // XACA-1178-008: an unrecognized credential prefix is never probed,
                // and the server never wrote last_validated_at for it — render this
                // distinctly from both success and an actual failed probe, so the
                // status text doesn't read as "we checked and it's broken".
                testStatusEl.textContent = data.error || 'Token present — not probed';
                testStatusEl.className = 'status-warning';
            } else {
                // XACA-1246 [UX-027], narrowed by [Review] findings 031/034:
                // this branch used to staple the addendum below onto the
                // ENTIRE generic-failure case unconditionally -- which also
                // caught the team-mismatch error, any resolver
                // credential_fault, REAL network/API failures (expired
                // token, timeout, 401), and finding 030's new
                // input-validation 400s. An operator whose credential
                // genuinely expired got a false causal explanation that
                // could read as "ignore this, it's migration noise."
                //
                // The server now emits an explicit `show_fallback_removed_note`
                // flag rather than leaving the client to infer this from
                // `data.error` text (see handle_team_account_test_connection's
                // matching comment for the exact signal: `team` known AND no
                // reported `credential_fault` -- precisely the pre-probe "no
                // token to test" state the old cross-team fallback used to
                // paper over; a real reported fault or an actual network
                // probe never sets it). Gating on a server-computed boolean,
                // not a string match, keeps this from re-triggering on
                // unrelated failure shapes.
                //
                // Wording no longer says "recent maintenance" ([Review]
                // finding 034: that phrasing has no time bound and goes
                // stale the moment it's read weeks later) -- it states the
                // mechanism plainly instead, which stays accurate
                // indefinitely rather than implying a recent event.
                testStatusEl.textContent = 'Failed: ' + (data.error || 'Unknown error') +
                    (data.show_fallback_removed_note
                        ? ' (Note: this team has no credential of its own configured. ' +
                          'Automatic fallback to another team’s credential is intentionally ' +
                          'not supported — configure this team’s own account/engine ' +
                          'assignment to resolve this.)'
                        : '');
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
        var authTypeInput = document.getElementById('team-account-edit-auth-type');
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
            env_var_name: envVarInput ? envVarInput.value.trim() : '',
            // XACA-1178-007: "" means not set -- server infers auth scheme
            // from the token prefix (XACA-0282-012 §1.2).
            auth_type: authTypeInput ? authTypeInput.value.trim() : ''
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
            var resp = await apiFetch(_apiUrl('/api/team-config/account/resume-ids'), {
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
                // XACA-0395 [UX-16]: carry status onto the Error so the catch below
                // can defer to api-auth.js's central 401 notifier instead of
                // double-toasting.
                var raErr = new Error(data.error || ('HTTP ' + resp.status));
                raErr.status = resp.status;
                throw raErr;
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
            // XACA-0395 [UX-16]: skip the redundant local toast on 401 — the central
            // auth-failure toast already told the user what happened.
            // XACA-0395-015: same skip on a network-level failure (isNetworkFailure) —
            // apiFetch() already showed its own distinct central toast for that case.
            if (!err || (err.status !== 401 && !err.isNetworkFailure)) {
                _showToast('Failed to apply resume-IDs action: ' + err.message, 'error');
            }
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
            var resp = await apiFetch(_apiUrl('/api/team-config/account/assign'), {
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
                // XACA-0395 [UX-16]: carry status onto the Error so the catch below
                // can defer to api-auth.js's central 401 notifier instead of
                // double-toasting.
                var assignErr = new Error(data.error || ('HTTP ' + resp.status));
                assignErr.status = resp.status;
                throw assignErr;
            }

            // Refresh the row to reflect new state (nickname, account_id, status dot).
            await _refreshTeamRow(teamSlug);

            // XACA-1246-006: never prescribe ~/.zshrc.secrets here — a
            // launchd-spawned LCARS server never reads it (that file is
            // sourced by INTERACTIVE shells only), so telling an operator to
            // edit it sends them down a dead end with no path forward. See
            // _credentialAssignLabel's own comment for the four states this
            // now distinguishes.
            var credLabel = _credentialAssignLabel(data);
            _showToast(
                teamSlug.toUpperCase() + ' → ' + accountSlug + ' assigned. ' + credLabel,
                data.has_credentials ? 'success' : 'warning'
            );

            // XACA-0281-008: Post-assign resume-IDs check.
            await _checkResumeIds(teamSlug, oldAccountId);
        } catch (err) {
            console.error('[team-account] assign failed:', err);
            // XACA-0395 [UX-16]: skip the redundant local toast on 401 — the central
            // auth-failure toast already told the user what happened.
            // XACA-0395-015: same skip on a network-level failure (isNetworkFailure) —
            // apiFetch() already showed its own distinct central toast for that case.
            if (!err || (err.status !== 401 && !err.isNetworkFailure)) {
                _showToast('Failed to assign account for ' + teamSlug + ': ' + err.message, 'error');
            }
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
            var resp = await apiFetch(_apiUrl('/api/team-config/account/save'), {
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
     *
     * XACA-1246 [UX] review finding: 'missing' used to collapse two very
     * different situations into one alarming red dot — a team that never
     * declared a credential at all (24 of 27, measured; the CORRECT, quiet
     * default) and a team whose DECLARED credential genuinely failed to
     * resolve (an actual fault). Split them: 'undeclared' for the former,
     * 'missing' reserved for the latter. Mirrors the same config_source /
     * env_var_name check _missingCredentialTooltip already used for its
     * copy — the dot now agrees with the tooltip instead of only the text
     * telling them apart.
     */
    function _resolveCredentialStatus(cfg) {
        if (!cfg || !cfg.has_credentials) {
            if (!cfg || cfg.config_source !== 'ai' || !cfg.env_var_name) {
                return 'undeclared';
            }
            return 'missing';
        }
        if (!cfg.last_validated_at) return 'unvalidated';
        var age = Date.now() - new Date(cfg.last_validated_at).getTime();
        var sevenDaysMs = 7 * 24 * 60 * 60 * 1000;
        return age <= sevenDaysMs ? 'ok' : 'unvalidated';
    }

    // ─────────────────────────────────────────────────────────────
    // XACA-1246-006: credential-state copy
    //
    // The credential is now resolved AT REQUEST TIME through
    // claude_code_cc_aliases.sh's vault/cache/env-var chain
    // (XACA-1246-003) — a launchd-spawned LCARS server's own frozen
    // process environment is no longer the source of truth, so
    // "edit ~/.zshrc.secrets and restart" is never correct advice: a
    // launchd-spawned server does not read ~/.zshrc / ~/.zshrc.secrets
    // at all (those are read by INTERACTIVE shells only), and even
    // where they would apply, no restart is needed — resolution is
    // re-checked on every request. These two helpers replace the old
    // single `has_credentials ? A : B` copy (which always named that
    // file) with copy that stays honest about which of four DISTINCT
    // states the server actually observed:
    //   1. resolved via the chain (vault | cache | env-failover | env-legacy)
    //   2. resolved via a direct env-var read ("env-direct" — the chain
    //      itself is not installed on this machine; every tap consumer)
    //   3. declared but unresolvable, WITH a reason (credential_fault)
    //   4. declared but unresolvable, with NO reason reported — say that
    //      plainly rather than inventing one (see the module header).
    // A 5th state — no team credential declared/decided at all (24 of 27
    // teams, measured) — is the CORRECT, quiet default and must not be
    // reported as if something were broken; see _missingCredentialTooltip.
    //
    // Do NOT read this as "check the vault" guidance for an operator —
    // fleet-monitor/server/data/vault.json does not exist on every box
    // and vault provisioning is tracked separately (XACA-1256); these
    // strings describe what THIS server observed, not a vault UI to go
    // look at.
    // ─────────────────────────────────────────────────────────────

    /** Human label for a resolver `mode` value. Mirrors claude_code_cc_aliases.sh's
     *  own chain vocabulary (vault | cache | env-failover | env-legacy) plus the
     *  server-side "env-direct" fallback mode (XACA-1246-003) — never invents a
     *  mode the resolver doesn't actually report. */
    function _credentialModeLabel(mode) {
        switch (mode) {
            case 'vault': return 'sealed vault';
            case 'cache': return 'offline vault cache';
            case 'env-failover': return 'env-var fallback (vault reachable, no key sealed there)';
            case 'env-legacy': return 'account env var (normal on this machine)';
            case 'env-direct': return 'direct environment read — no vault/cache chain installed here';
            default: return mode || 'the credential chain';
        }
    }

    /** Toast copy for a resolved (has_credentials=true) result. */
    function _credentialResolvedLabel(data) {
        return 'Key credential resolved via ' + _credentialModeLabel(data && data.credential_source) + '.';
    }

    /** Toast copy for an unresolved (has_credentials=false) result — NEVER
     *  prescribes editing ~/.zshrc.secrets, which a launchd-spawned server
     *  cannot see (XACA-1246). Distinguishes a reported fault from the
     *  honest "no reason given" case rather than guessing one.
     *
     *  Deliberately does NOT say "the chain reported no specific reason":
     *  `credential_source`/`mode` is null on EVERY unresolved outcome,
     *  including a tap consumer where the chain (claude_code_cc_aliases.sh)
     *  isn't installed at all and was never consulted — server.py falls
     *  straight to a direct env-var read there (XACA-1246-003's env-direct
     *  fallback). Claiming "the chain" ran and declined would be false on
     *  that machine, so this stays mechanism-neutral instead. */
    function _credentialUnresolvedLabel(data) {
        var fault = data && data.credential_fault;
        var suffix = ' Re-checked on every request — no restart needed once fixed; '
            + 'a shell rc-file edit will not reach this server.';
        if (fault) {
            return 'Key credential NOT resolved: ' + fault + '.' + suffix;
        }
        return 'Key credential NOT resolved, and no specific reason was reported.' + suffix
            + ' Verify the account/engine assignment above.';
    }

    /** Combined toast label for the assign response. */
    function _credentialAssignLabel(data) {
        return (data && data.has_credentials)
            ? _credentialResolvedLabel(data)
            : _credentialUnresolvedLabel(data);
    }

    /** Status-dot tooltip for the 'missing' status. Kept DISTINCT from
     *  _credentialUnresolvedLabel's toast copy: the common case here (24 of
     *  27 teams, measured) is "no team credential declared/decided" —
     *  correct and quiet, not a fault — so this checks config_source/
     *  env_var_name FIRST and only reports a fault when one was actually
     *  declared and failed to resolve.
     *
     *  XACA-1246 review finding: this tooltip's data comes from
     *  serve_team_account_current -> _resolve_team_credential(team,
     *  want_value=False) WITHOUT force=True, which is allowed to answer
     *  from the server's 30s TTL outcome cache
     *  (_CREDENTIAL_RESOLVE_CACHE_TTL). Assign and TEST CONNECTION both
     *  pass force=True and genuinely re-resolve on every call; this
     *  display does not, so its copy must not claim per-request precision
     *  it doesn't have — say "continuously" (bounded by the cache TTL),
     *  never "on every request". Forcing an uncached resolve here instead
     *  would spawn a resolver subprocess per team on every panel load (up
     *  to 27 teams) purely to freshen a tooltip — not worth the cost. */
    function _missingCredentialTooltip(cfg) {
        if (!cfg || cfg.config_source !== 'ai' || !cfg.env_var_name) {
            // Undeclared (no ai.credential key at all), or a declared
            // explicit-null "no team credential" decision — both are the
            // CORRECT state for a team using the CLI's own default login,
            // not a failure. XACA-0282-012 three-state contract: absence
            // and null both mean "no team credential", never falsiness.
            return 'No team account assigned — this team uses the CLI’s default login.';
        }
        var fault = cfg.credential_fault;
        if (fault) {
            return 'Declared credential (' + cfg.env_var_name + ') could not be resolved: ' + fault
                + '. Re-checked continuously (within seconds) — no restart needed once fixed.';
        }
        // Mechanism-neutral for the same reason as _credentialUnresolvedLabel
        // above — mode is null here whether a chain ran and found nothing
        // or no chain exists on this machine at all; never claim "the chain".
        return 'Declared credential (' + cfg.env_var_name + ') did not resolve, and no specific reason '
            + 'was reported. Re-checked continuously (within seconds) — verify the account assignment above.';
    }

    /** Fill the modal input fields from a config object (or clear them). */
    function _fillModalFields(cfg) {
        var acctIdInput = document.getElementById('team-account-edit-account-id');
        var nickInput = document.getElementById('team-account-edit-nickname');
        var envVarInput = document.getElementById('team-account-edit-env-var');
        var authTypeInput = document.getElementById('team-account-edit-auth-type');

        if (acctIdInput) acctIdInput.value = (cfg && cfg.account_id) ? cfg.account_id : '';
        if (nickInput) nickInput.value = (cfg && cfg.account_nickname) ? cfg.account_nickname : '';
        if (envVarInput) envVarInput.value = (cfg && cfg.env_var_name) ? cfg.env_var_name : '';
        // XACA-1178-007: auth_type is optional -- "" selects the "(not set,
        // infer from token)" option, matching the server's prefix-inference
        // fallback (XACA-0282-012 §1.2).
        if (authTypeInput) authTypeInput.value = (cfg && cfg.auth_type) ? cfg.auth_type : '';
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
     * XACA-1246 [UX] review finding: the credential-status copy this ticket
     * introduced (_credentialResolvedLabel / _credentialUnresolvedLabel /
     * _credentialAssignLabel) runs ~4-9x longer than the old fixed string
     * ('Key env var detected.'), but every call site here that doesn't pass
     * an explicit duration fell through to the global showToast's fixed 6s
     * (warning/error) or 3s (success/info) default regardless of message
     * length. Scale it: keep the same base default, then add reading time
     * for whatever runs past a short baseline (~200wpm / ~17 chars-per-sec
     * average adult reading speed -> ~60ms/char; rounded up a little to
     * leave margin), capped so one message can't pin the toast open
     * indefinitely. Local to this file's `_showToast` wrapper only — the
     * shared global `showToast` in lcars.js (used by the rest of the app)
     * is untouched, and any call site here that already passes an explicit
     * `duration` (e.g. the two 8000ms Fleet-Monitor toasts above) keeps it
     * verbatim; this only fills in when the caller left it unset.
     */
    function _autoToastDuration(message, type) {
        var base = (type === 'error' || type === 'warning') ? 6000 : 3000;
        var msg = message || '';
        var BASELINE_LEN = 40;   // messages this short or shorter need no bonus
        var MS_PER_CHAR = 60;
        var MAX_DURATION = 15000;
        var extra = Math.max(0, msg.length - BASELINE_LEN) * MS_PER_CHAR;
        return Math.min(base + extra, MAX_DURATION);
    }

    /**
     * Delegate to the global showToast from lcars.js (line ~357).
     * Falls back to console.log if not yet available (shouldn't happen in practice
     * since lcars.js loads before this file).
     */
    function _showToast(message, type, duration) {
        var resolvedType = type || 'info';
        var resolvedDuration = (duration != null) ? duration : _autoToastDuration(message, resolvedType);
        if (typeof showToast === 'function') {
            showToast(message, resolvedType, resolvedDuration);
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
