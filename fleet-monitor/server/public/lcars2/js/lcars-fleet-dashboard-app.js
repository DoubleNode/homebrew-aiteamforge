//
//  lcars-fleet-dashboard-app.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * LCARS Unified Fleet Dashboard Application (XACA-1110)
 *
 * Config-parameterized replacement for the 4 former byte-near-identical
 * lcars2 dashboard app files (lcars-{academy,doublenode,mainevent,all}-app.js
 * -- see git history / XACA-1110 for the originals). One module, driven by
 * `window.LCARS_DASHBOARD_CONFIG` (set by whichever per-org config script
 * the host page loads immediately before this one -- lcars-academy-config.js,
 * lcars-doublenode-config.js, lcars-mainevent-config.js, or
 * lcars-all-config.js). See
 * ~/dev-team/kanban/plans/XACA-1110/XACA-1110-design-decision.md for the
 * full rationale (D1-D8); do not reintroduce a per-org branch or registry
 * here (D5 -- the unified module must contain NO org registry).
 *
 * The only structural fork in this file is the single derived predicate
 * `isUnbounded` (D1), branching at exactly two call sites: whether
 * fetchFleetData() filters the response, and whether DOMContentLoaded
 * awaits fetchTeamConfig() before its first render.
 */

(function() {
    'use strict';

    // ============================================================================
    // CONFIGURATION
    // ============================================================================

    // D5: config-via-global, set by whichever lcars-<org>-config.js the
    // host page loaded immediately before this script. The three keys
    // merged in here (apiBase/refreshInterval/stardateOffset) are
    // byte-identical across all four former files and stay module-internal
    // -- they are not config (design decision doc, "Consolidated config
    // surface").
    const CONFIG = Object.assign({
        apiBase: window.location.origin,
        refreshInterval: 60000,
        stardateOffset: 41000
    }, window.LCARS_DASHBOARD_CONFIG);

    if (!window.LCARS_DASHBOARD_CONFIG) {
        // Loud on purpose -- mirrors the window.LCARS_ORG guard idiom in
        // getOrganizationGroup()/getGroupColor() below, and exists for the
        // same reason: a missing dependency must not masquerade as valid
        // state. Object.assign(target, undefined) above is a silent no-op,
        // so without this guard CONFIG.divisions stays undefined,
        // isUnbounded (below) resolves to (undefined === null) === false,
        // filterData() then throws on CONFIG.divisions.includes(...), and
        // fetchFleetData()'s catch swallows that TypeError into a generic
        // "connection lost" -- misdiagnosing a deployment fault (the
        // per-org config script 404ing, or its <script> tag loading after
        // this one instead of before it, per D5/D6) as a network one.
        console.error('[LCARS][config] window.LCARS_DASHBOARD_CONFIG is not set -- '
            + 'the per-org config script (lcars-<org>-config.js) must be loaded '
            + 'BEFORE this script. Falling back to an empty division list so the '
            + 'dashboard fails visibly (no data rendered) instead of throwing.');
        // Defaulted to [] rather than null (which would mean "unbounded" --
        // render everything unfiltered): D5 forbids this module guessing at
        // a per-org division list, and [] is enough to keep filterData()
        // from throwing without silently rendering unfiltered fleet data
        // under a dashboard name (CONFIG.dashboardName) that is itself
        // undefined.
        CONFIG.divisions = [];
    }

    const LCARS_PORT = 8080;

    // D1: the ONE derived predicate. `null` divisions means "unbounded" --
    // render every division the API returns rather than filtering to a
    // fixed set, and source division ordering/priority from a live team
    // config fetch instead of a static map. Everything else in this file
    // branches on this single boolean at exactly two call sites (see
    // fetchFleetData() and the DOMContentLoaded handler below) -- no
    // lifecycle hooks, no capability-flag triple.
    const isUnbounded = (CONFIG.divisions === null);

    // ============================================================================
    // STATE
    // ============================================================================

    let fleetData = null;
    let refreshTimer = null;
    let expandedSystemMachineId = null;  // XACA-1092-005: DOM identity for the SYSTEM disclosure toggle -- string, not an element ref, so expand state survives renderMachines() rebuilding the list every refresh tick (mirrors v1's expandedBackupMachineId).
    let teamConfig = null;  // D1: always declared (even on filtered dashboards, where it stays null forever -- fetchTeamConfig() is never called for them). Dynamic team configuration from board files, used only when isUnbounded.

    // ============================================================================
    // INITIALIZATION
    // ============================================================================

    // D1.4: this handler is `async` for ALL four dashboards (accepted
    // non-change -- an async handler that never reaches its `await` on the
    // taken path resolves in the same microtask, and the DOM discards a
    // listener's return value, so nothing observes handler completion; the
    // three filtered dashboards never reach the `await` below). Pinned by
    // tests/xaca-1110-004-dashboard-differential-harness.test.js's D1.4
    // checks against the pre-unification files.
    document.addEventListener('DOMContentLoaded', async function() {
        console.log('[LCARS] ' + CONFIG.dashboardName + ' Dashboard initializing...');

        // Initialize LCARS core
        if (window.LCARS_CORE) {
            LCARS_CORE.init({
                candyOptions: { section: CONFIG.candySection }
            });
        }

        // Initialize Kiosk Mode (auto-rotation on idle)
        if (window.LCARS_KIOSK) {
            LCARS_KIOSK.init();
        }

        // XACA-0989: Expand All / Collapse All control for the divisions
        // section -- wired once; #divisions-container's re-renders don't
        // touch it.
        if (window.LCARS_DIVISIONS) {
            const divisionsContainer = document.getElementById('divisions-container');
            const sectionHeader = divisionsContainer && divisionsContainer.previousElementSibling;
            if (sectionHeader) {
                window.LCARS_DIVISIONS.wireExpandCollapseAll(sectionHeader);
            }
        }

        // D1 call site 2: only the unbounded ('all') dashboard needs a
        // runtime division source -- the three filtered dashboards already
        // know their divisions statically (CONFIG.divisions) and issue zero
        // extra network requests. Matches the original lcars-all-app.js
        // ordering (team config fetched before the first fleet fetch).
        if (isUnbounded) {
            await fetchTeamConfig();
        }

        // Initial data fetch
        fetchFleetData();

        // Set up auto-refresh
        refreshTimer = setInterval(fetchFleetData, CONFIG.refreshInterval);

        // Update stardate
        updateStardate();
        setInterval(updateStardate, 1000);

        console.log('[LCARS] ' + CONFIG.dashboardName + ' Dashboard initialized');
    });

    // ============================================================================
    // DATA FETCHING
    // ============================================================================

    // D1: fetchTeamConfig() is always defined so the module's shape does
    // not depend on config -- it is only ever CALLED from the
    // DOMContentLoaded branch above when isUnbounded.
    /**
     * Fetch team configuration for dynamic organization mapping
     * Teams are auto-discovered from kanban board files
     */
    async function fetchTeamConfig() {
        try {
            const response = await fetch(CONFIG.apiBase + '/api/team-config');
            if (response.ok) {
                teamConfig = await response.json();
                console.log('[LCARS] Team config loaded:', Object.keys(teamConfig.teams).length, 'teams');
            }
        } catch (error) {
            console.warn('[LCARS] Could not fetch team config, using defaults:', error.message);
        }
    }

    async function fetchFleetData() {
        try {
            const response = await fetch(CONFIG.apiBase + '/api/fleet');
            if (!response.ok) {
                throw new Error('HTTP ' + response.status + ': ' + response.statusText);
            }
            fleetData = await response.json();
            // D1 call site 1: the unbounded ('all') dashboard renders the
            // raw response -- nothing to filter, every division is its own.
            // The three filtered dashboards narrow to CONFIG.divisions via
            // filterData(), which the ternary below only ever calls on
            // that (non-unbounded) path.
            renderDashboard(isUnbounded ? fleetData : filterData(fleetData));
            updateConnectionStatus(true);
        } catch (error) {
            console.error('[LCARS] Failed to fetch fleet data:', error);
            updateConnectionStatus(false);
        }
    }

    // D1: declared unconditionally so every filtered dashboard's call site
    // above resolves the identifier the same way; assigned a real function
    // ONLY when !isUnbounded (there is nothing to filter on an unbounded
    // dashboard -- D1's rejected option (a) is exactly the no-op-filterData
    // shape this avoids). `typeof filterData` therefore reads "undefined"
    // for the 'all' config -- the exact contract
    // tests/helpers/lcars-fleet-dashboard-jsdom-loader.js's loadDashboardModule()
    // export bridge (and this ticket's differential harness) checks.
    let filterData;
    if (!isUnbounded) {
        filterData = function(data) {
            if (!data || !data.fleet) return data;

            const fleet = data.fleet;
            const filteredDivisions = {};
            let filteredTotalSessions = 0;

            for (const divisionName in fleet.divisions || {}) {
                if (CONFIG.divisions.includes(divisionName.toLowerCase())) {
                    filteredDivisions[divisionName] = fleet.divisions[divisionName];
                    filteredTotalSessions += fleet.divisions[divisionName].total_sessions || 0;
                }
            }

            const filteredMachines = (fleet.machines || []).map(function(machine) {
                const filteredSessions = (machine.sessions || []).filter(function(session) {
                    return CONFIG.divisions.includes((session.division || '').toLowerCase());
                });
                return Object.assign({}, machine, {
                    sessions: filteredSessions,
                    session_count: filteredSessions.length
                });
            }).filter(function(machine) {
                return machine.session_count > 0;
            });

            const onlineMachines = filteredMachines.filter(function(m) { return m.status === 'online'; }).length;
            const offlineMachines = filteredMachines.filter(function(m) { return m.status === 'offline'; }).length;

            return {
                fleet: {
                    total_machines: filteredMachines.length,
                    online_machines: onlineMachines,
                    offline_machines: offlineMachines,
                    total_sessions: filteredTotalSessions,
                    divisions: filteredDivisions,
                    machines: filteredMachines
                },
                last_update: data.last_update
            };
        };
    }

    // ============================================================================
    // RENDERING
    // ============================================================================

    function renderDashboard(data) {
        if (!data || !data.fleet) {
            console.warn('[LCARS] No fleet data to render');
            return;
        }

        const fleet = data.fleet;
        const lastUpdate = data.last_update;

        // Update summary cards
        updateElement('total-machines', fleet.total_machines || 0);
        updateElement('online-machines', fleet.online_machines || 0);
        updateElement('offline-machines', fleet.offline_machines || 0);
        updateElement('total-sessions', fleet.total_sessions || 0);
        updateElement('last-update', formatTimestamp(lastUpdate));

        // Update LCARS candy pills
        if (window.LCARS_CORE && LCARS_CORE.candy) {
            LCARS_CORE.candy.updateData({
                totalMachines: fleet.total_machines || 0,
                onlineMachines: fleet.online_machines || 0,
                offlineMachines: fleet.offline_machines || 0,
                totalSessions: fleet.total_sessions || 0
            });
        }

        // Render divisions
        renderDivisions(fleet.divisions);

        // Render machines
        renderMachines(fleet.machines);
    }

    function renderOrganizationNav(sortedOrgs, organizationGroups) {
        const navContainer = document.getElementById('organization-nav');
        if (!navContainer) return;

        navContainer.innerHTML = '';

        sortedOrgs.forEach(function(orgName) {
            const divisionCount = organizationGroups[orgName].length;
            const totalSessions = organizationGroups[orgName].reduce(function(sum, item) {
                return sum + item[1].total_sessions;
            }, 0);

            const navButton = document.createElement('button');
            navButton.className = 'org-nav-button ' + getGroupColor(orgName);
            // textContent, not innerHTML: orgName arrives from the `organization`
            // field of /api/team-register's body, validated for presence only, so
            // innerHTML made this an injection sink for any API-key holder.
            // (XACA-0970, review gate.)
            const navName = document.createElement('span');
            navName.className = 'org-nav-name';
            navName.textContent = orgName;
            navButton.appendChild(navName);

            const navStats = document.createElement('span');
            navStats.className = 'org-nav-stats';
            navStats.textContent = divisionCount + ' Divisions • ' + totalSessions + ' Sessions';
            navButton.appendChild(navStats);

            navButton.onclick = function() {
                const targetId = 'org-' + orgName.toLowerCase().replace(/\s+/g, '-');
                const targetElement = document.getElementById(targetId);
                if (targetElement) {
                    targetElement.scrollIntoView({ behavior: 'smooth', block: 'start' });
                }
            };

            navContainer.appendChild(navButton);
        });
    }

    function renderDivisions(divisions) {
        const container = document.getElementById('divisions-container');
        // XACA-0989-019: beginRenderPass()/endRenderPass() must bracket the
        // ENTIRE render pass, including this early "no container" exit --
        // not just the body below it. Before this fix, a missing container
        // returned before beginRenderPass() ever ran, so the PREVIOUS pass's
        // controllers array was left in place, still registered against
        // whatever nodes it pointed at (now potentially detached, since a
        // container going missing usually means the DOM around it changed).
        // A later notifyStateChange() (e.g. from a toggle click elsewhere)
        // would then call applyState() against those stale controllers.
        if (window.LCARS_DIVISIONS) window.LCARS_DIVISIONS.beginRenderPass();
        if (!container) {
            if (window.LCARS_DIVISIONS) window.LCARS_DIVISIONS.endRenderPass();
            return;
        }

        container.innerHTML = '';

        if (!divisions || Object.keys(divisions).length === 0) {
            container.innerHTML = '<p class="empty-message">' + CONFIG.emptyMessage + '</p>';
            if (window.LCARS_DIVISIONS) window.LCARS_DIVISIONS.endRenderPass();
            return;
        }

        // Group divisions by organization
        const organizationGroups = {};

        for (const divisionName in divisions) {
            const orgGroup = getOrganizationGroup(divisionName);
            if (!organizationGroups[orgGroup]) {
                organizationGroups[orgGroup] = [];
            }
            organizationGroups[orgGroup].push([divisionName, divisions[divisionName]]);
        }

        const sortedOrgs = Object.keys(organizationGroups).sort();
        renderOrganizationNav(sortedOrgs, organizationGroups);

        sortedOrgs.forEach(function(orgName) {
            const orgContainer = document.createElement('div');
            orgContainer.className = 'organization-panel ' + getGroupColor(orgName);
            orgContainer.id = 'org-' + orgName.toLowerCase().replace(/\s+/g, '-');

            const totalSessions = organizationGroups[orgName].reduce(function(sum, item) {
                return sum + item[1].total_sessions;
            }, 0);

            const orgHeader = document.createElement('div');
            orgHeader.className = 'organization-header';
            // textContent, not innerHTML -- same untrusted `organization` field as the
            // nav button above. (XACA-0970, review gate.)
            const orgTitle = document.createElement('span');
            orgTitle.className = 'organization-title';
            orgTitle.textContent = orgName;
            orgHeader.appendChild(orgTitle);

            const orgCount = document.createElement('span');
            orgCount.className = 'organization-count';
            orgCount.textContent = totalSessions + ' Sessions';
            orgHeader.appendChild(orgCount);
            // XACA-0970-012: the UNKNOWN heading carries its own remediation.
            // All of the policy lives in the shared module -- see decorateHeading().
            if (window.LCARS_ORG && window.LCARS_ORG.decorateHeading) {
                window.LCARS_ORG.decorateHeading(orgHeader, orgName);
            }
            orgContainer.appendChild(orgHeader);

            // Sort divisions by priority
            const sortedDivisions = organizationGroups[orgName].sort(function(a, b) {
                const priorityA = getDivisionPriority(a[0]);
                const priorityB = getDivisionPriority(b[0]);
                if (priorityA !== priorityB) return priorityA - priorityB;
                return getDivisionTitle(a[0]).localeCompare(getDivisionTitle(b[0]));
            });

            sortedDivisions.forEach(function(item) {
                const divisionPanel = createDivisionPanel(item[0], item[1]);
                orgContainer.appendChild(divisionPanel);
            });

            container.appendChild(orgContainer);
        });

        // XACA-0989: refresh the Expand All / Collapse All label now that
        // this pass's division set (and each panel's initial paint) is final.
        if (window.LCARS_DIVISIONS) window.LCARS_DIVISIONS.endRenderPass();
    }

    function createDivisionPanel(name, data) {
        const panel = document.createElement('div');
        panel.className = 'division-container';
        panel.id = 'div-' + name.toLowerCase().replace(/\s+/g, '-');

        const header = document.createElement('div');
        header.className = 'division-header';
        // XACA-0989: '.division-toggle-icon' is filled in by
        // LCARS_DIVISIONS.wireDivisionToggle() below -- empty here.
        // XACA-0416-004: getDivisionTitle() falls through to `code.toUpperCase()`
        // for ANY unrecognised division code, and `division` is copied verbatim
        // from the reporter's POSTed session payload (server.js parseFleetData ->
        // resolveDivisionKey), so an unknown code arrives here as attacker-
        // influenced text. Element content -> escapeHtml. data.total_sessions is a
        // server-side integer counter, never interpolated input -> unwrapped.
        header.innerHTML = escapeHtml(getDivisionTitle(name)) +
            '<span class="division-stats">' + data.total_sessions + ' Sessions' +
            '<span class="division-toggle-icon" aria-hidden="true"></span></span>';
        panel.appendChild(header);

        const content = document.createElement('div');
        content.className = 'teams-grid';

        // XACA-0989: collected alongside the (unchanged) expanded cards so
        // the collapsed chip view never has to re-walk data.projects.
        const chipEntries = [];

        for (const projectKey in data.projects) {
            const projectData = data.projects[projectKey];
            // XACA-1002-014: LCARS terminals first, then live before
            // idle-registered, then alphabetical. Extracted to the shared
            // module -- this comparator was previously inline in all five
            // app files, the copy-paste shape that module exists to prevent.
            const teamNames = Object.keys(projectData.teams).sort(
                LCARS_TERMINAL_CARD.createTeamNameComparator(projectData.teams)
            );
            teamNames.forEach(function(teamName) {
                const teamCard = createTeamCard(teamName, projectData.teams[teamName]);
                content.appendChild(teamCard);
                chipEntries.push([teamName, projectData.teams[teamName]]);
            });
        }

        panel.appendChild(content);

        // XACA-0989: collapsed-by-default chip view, single shared renderer
        // (shared/js/lcars-division-collapse.js). Fails safe to the
        // pre-XACA-0989 always-expanded behavior if the module didn't load.
        if (window.LCARS_DIVISIONS) {
            const chipRow = window.LCARS_DIVISIONS.buildChipRow(chipEntries, {
                isLcarsTerminal: isLcarsTerminal,
                getLcarsUrl: getLcarsUrl
            });
            panel.insertBefore(chipRow, content);
            window.LCARS_DIVISIONS.wireDivisionToggle(panel, header, chipRow, content);
        }

        return panel;
    }

    function escapeHtml(text) {
        if (!text) return '';
        const div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
    }

    // XACA-0416 (UX/Test finding): session.theme_color is a CSS context, not an
    // HTML one -- the same class safeCssIdent() exists for, but a colour is not
    // an identifier, so it needs its own allowlist rather than that one.
    //
    // server.js stores theme_color VERBATIM from the reporter's POST (the
    // endpoint validates presence, not shape) and it was assigned straight into
    // `teamNameEl.style.cssText`. cssText REPLACES the whole declaration block,
    // so a value like `red; position:fixed; font-size:900px; z-index:9999` is a
    // genuine style injection on every operator's dashboard, not a cosmetic
    // glitch. No HTML escaper closes it: `;` and `:` are not HTML-special, so
    // escapeAttr() hands that payload back byte-for-byte intact.
    //
    // ACCEPTED: #RGB, #RGBA, #RRGGBB, #RRGGBBAA, plus a conservative set of CSS
    // named colours. Every theme file the fleet actually ships is #RRGGBB
    // (fleet-reporter.sh's get_theme_color() cats lcars-ports/<session>.theme),
    // so the hex branch covers production and the named set is slack for a
    // hand-edited file. rgb()/rgba() are deliberately NOT accepted: admitting
    // them means validating three or four numeric components and their
    // separators, and nothing in the fleet emits them, so that parser would be
    // untested surface bought for no caller.
    //
    // REJECTION TAKES THE NO-THEME PATH: it returns '' and the caller skips the
    // whole styling block, which is byte-identical to what already happens when
    // theme_color is absent. It does not substitute a colour of its own.
    var CSS_NAMED_COLORS = {
        aqua: 1, black: 1, blue: 1, cyan: 1, fuchsia: 1, gold: 1, gray: 1,
        green: 1, grey: 1, indigo: 1, lavender: 1, lime: 1, magenta: 1,
        maroon: 1, navy: 1, olive: 1, orange: 1, orchid: 1, pink: 1, purple: 1,
        red: 1, salmon: 1, silver: 1, tan: 1, teal: 1, tomato: 1, turquoise: 1,
        violet: 1, white: 1, yellow: 1
    };

    var _warnedCssColors = Object.create(null);

    function safeCssColor(value) {
        var s = (value === null || value === undefined) ? '' : String(value).trim();
        if (/^#(?:[0-9A-Fa-f]{8}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{4}|[0-9A-Fa-f]{3})$/.test(s)) {
            return s;
        }
        if (Object.prototype.hasOwnProperty.call(CSS_NAMED_COLORS, s.toLowerCase())) {
            return s;
        }
        // XACA-0416-025 (PR #784 UX gate): rejecting SILENTLY makes a mistyped or
        // unsupported theme indistinguishable from no theme at all -- the card
        // simply renders unstyled and nobody learns why. Warn once per distinct
        // value (not per render: createTeamCard runs on every poll, so an
        // unthrottled warn would flood the console). Measured zero live impact
        // today -- all 86 shipped .theme files are 6-digit hex -- so this is
        // diagnosability for hand-edited values, not a live fix.
        if (s && !_warnedCssColors[s]) {
            _warnedCssColors[s] = true;
            if (typeof console !== 'undefined' && console.warn) {
                console.warn('[LCARS] theme_color rejected, rendering untinted: ' + s +
                    ' (accepted: #RGB/#RGBA/#RRGGBB/#RRGGBBAA or a supported colour name)');
            }
        }
        return '';
    }

    // XACA-0983 fix (b), third render state: a team can be a KNOWN LCARS
    // service (data.lcars_service, from server.js's parseFleetData -- see
    // fleet-reporter.sh's get_lcars_services()) with NO live tmux session.
    // Before this, createTeamCard returned an EMPTY card for every
    // session-less team, so a genuinely-down (or simply session-less-but-
    // healthy) LCARS terminal rendered identically to "not an LCARS
    // terminal at all" -- the same silent-absence bug this ticket exists to
    // fix, just moved one layer up. This function is called ONLY when
    // isLcarsTerminal(data) is true AND there is no session, so a team that
    // was never an LCARS terminal is unaffected and still gets the original
    // empty card below.
    // XACA-0990: extracted to shared/js/lcars-terminal-card.js. This shim
    // preserves the local call site verbatim; escapeHtml (still defined in
    // this file, it has other callers) is injected as the module has no
    // access to this scope.
    function createServiceOnlyLcarsCard(name, svc) {
        return LCARS_TERMINAL_CARD.createServiceOnlyLcarsCard(name, svc, escapeHtml);
    }

    // XACA-1002: a team can be REGISTERED (present in the team registry /
    // port map) with no live session and no lcars_service -- server.js's
    // parseFleetData synthesizes a session-less "idle" bucket for it
    // (data.idle_registered). This shim preserves the local call site
    // pattern established by createServiceOnlyLcarsCard above; escapeHtml
    // (still defined in this file, it has other callers) is injected as
    // the module has no access to this scope.
    function createIdleTeamCard(name, idle) {
        return LCARS_TERMINAL_CARD.createIdleTeamCard(name, idle, escapeHtml);
    }

    function createTeamCard(name, data) {
        const card = document.createElement('div');
        const isLcars = isLcarsTerminal(data);
        card.className = isLcars ? 'team-card lcars-terminal' : 'team-card';

        const session = data.sessions && data.sessions[0];
        if (!session) {
            if (isLcars && data.lcars_service) {
                return createServiceOnlyLcarsCard(name, data.lcars_service);
            }
            // XACA-1002: gate on the idle_registered marker specifically --
            // never call the idle renderer unconditionally, or a genuinely
            // malformed bucket (no sessions, no lcars_service, no marker)
            // would render a misleading "idle" card instead of the original
            // empty fallback below.
            if (data.idle_registered) {
                return createIdleTeamCard(name, data.idle_registered);
            }
            return card;
        }

        const status = session.machine_status || 'offline';
        const isOnline = status === 'online';

        card.innerHTML =
            '<div class="team-header">' +
                '<div class="team-name">' + escapeHtml(name) + (isLcars ? '<span class="lcars-badge">LCARS</span>' : '') + '</div>' +
                '<span class="status-indicator ' + status + '"></span>' +
            '</div>' +
            '<div class="session-info">' +
                '<div class="session-detail"><span class="session-label">Session:</span><span class="session-value">' + escapeHtml(session.name) + '</span></div>' +
                '<div class="session-detail"><span class="session-label">Machine:</span><span class="session-value">' + escapeHtml(session.hostname) + '</span></div>' +
                '<div class="session-detail"><span class="session-label">Windows:</span><span class="session-value">' + escapeHtml(session.windows == null ? '' : String(session.windows)) + '</span></div>' +
                '<div class="session-detail"><span class="session-label">Uptime:</span><span class="session-value">' + escapeHtml(session.uptime_display) + '</span></div>' +
                '<div class="session-detail"><span class="session-label">Status:</span><span class="session-value text-' + status + '">' + status.toUpperCase() + '</span></div>' +
            '</div>';

        // Apply theme color to non-LCARS cards
        // XACA-0416: validate BEFORE either style sink, and gate the whole block
        // on the VALIDATED value -- an unrecognised theme_color renders exactly
        // like no theme_color at all.
        var themeColor = safeCssColor(session.theme_color);
        if (themeColor && !isLcars) {
            card.style.borderLeft = '4px solid ' + themeColor;
            var teamNameEl = card.querySelector('.team-name');
            if (teamNameEl) {
                // Single-property write instead of cssText: cssText replaces the
                // ENTIRE declaration block, and setProperty is the narrower sink.
                // Behaviour-preserving here -- teamNameEl is built fresh from this
                // card's innerHTML and carries no other inline declaration -- and
                // setProperty keeps the `!important` that a plain
                // `style.color = ...` assignment cannot express.
                teamNameEl.style.setProperty('color', themeColor, 'important');
            }
        }

        if (isLcars) {
            const lcarsUrl = getLcarsUrl(data);
            if (lcarsUrl && isOnline) {
                card.classList.add('lcars-clickable');
                card.title = 'Click to open LCARS terminal: ' + lcarsUrl;
                // XACA-0983-014: same keyboard-activation support as the
                // service-only card above -- see createServiceOnlyLcarsCard.
                card.setAttribute('tabindex', '0');
                card.setAttribute('role', 'button');
                card.addEventListener('click', function() {
                    window.open(lcarsUrl, '_blank');
                });
                card.addEventListener('keydown', function(evt) {
                    if (evt.key === 'Enter' || evt.key === ' ' || evt.key === 'Spacebar' || evt.keyCode === 13 || evt.keyCode === 32) {
                        evt.preventDefault();
                        window.open(lcarsUrl, '_blank');
                    }
                });
            } else if (lcarsUrl && !isOnline) {
                // XACA-0979: match the flat dashboards' offline treatment so one
                // team's card behaves identically in every dashboard view.
                card.classList.add('lcars-offline');
                card.title = 'LCARS terminal unavailable - machine is ' + status;
            } else {
                // XACA-0979: no hostname reported for this session - never leave
                // the card looking actionable without saying why.
                card.classList.add('lcars-offline');
                card.title = 'LCARS terminal misconfigured - no hostname reported for this session';
            }
        }

        return card;
    }

    function renderMachines(machines) {
        const container = document.getElementById('machines-list');
        if (!container) return;

        container.innerHTML = '';

        if (!machines || machines.length === 0) {
            container.innerHTML = '<p class="empty-message">' + CONFIG.machinesEmptyMessage + '</p>';
            return;
        }

        // XACA-1100-022: hoisted OUT of the forEach that used to hold this
        // check (see git blame). Inside the loop it re-evaluated -- and on
        // failure re-logged -- once PER MACHINE on every refresh tick: ~120
        // identical console.error calls/min for a ten-machine fleet on the
        // 5s poll, burying every other diagnostic in the console. The
        // condition does not depend on `machine`, so it only needs to run
        // once per render. On failure this also now paints a VISIBLE message
        // into the container (same idiom as the empty-state branch above)
        // instead of leaving it silently blank: a blank machines list reads
        // to an operator as "no machines detected", which is a false
        // negative on an operator-facing fleet dashboard -- worse than a
        // loud, explicit error. See the window.LCARS_CORE/LCARS_KIOSK/
        // LCARS_DIVISIONS/LCARS_ORG guard idiom used throughout this file
        // (getOrganizationGroup()/getGroupColor() etc.) -- loud-on-purpose,
        // matching that pattern, rather than a bare optional-chaining no-op.
        if (!window.LCARS_CORE || !window.LCARS_CORE.machines) {
            console.error('[LCARS][machines] lcars2/js/lcars-fleet-core.js is not '
                + 'loaded -- it must appear BEFORE this script. Skipping render for all '
                + machines.length + ' machine(s).');
            container.innerHTML = '<p class="empty-message render-error">'
                + 'Machine renderer unavailable -- lcars-fleet-core.js failed to load. '
                + 'Check the browser console.</p>';
            return;
        }

        const sortedMachines = machines.sort(function(a, b) {
            if (a.status !== b.status) {
                return a.status === 'online' ? -1 : 1;
            }
            return a.hostname.localeCompare(b.hostname);
        });

        sortedMachines.forEach(function(machine) {
            // XACA-1100-003: createMachineItem() itself now lives in the shared
            // lcars2 core (lcars-fleet-core.js, extracted XACA-1100-002 from four
            // byte-identical copies of this function). It runs OUTSIDE this file's
            // closure, so it cannot see machineSystemToHealthInput/healthBadgeSpec/
            // buildSystemSectionHtml/toggleSystemPanel/expandedSystemMachineId,
            // which all remain owned HERE (per-dashboard state/logic, not
            // duplicated) -- deps wires them in.
            //
            // XACA-1100-022: the window.LCARS_CORE/.machines guard that used to
            // sit here was hoisted ABOVE this forEach (see there) so it runs
            // once per render instead of once per machine -- this callback can
            // now assume window.LCARS_CORE.machines is present.
            const item = window.LCARS_CORE.machines.createMachineItem(machine, {
                machineSystemToHealthInput: machineSystemToHealthInput,
                healthBadgeSpec: healthBadgeSpec,
                buildSystemSectionHtml: buildSystemSectionHtml,
                toggleSystemPanel: toggleSystemPanel,
                isSystemExpanded: expandedSystemMachineId === machine.machine_id
            });
            container.appendChild(item);
        });
    }

    // ============================================================================
    // XACA-1092-004/-005: MACHINE SYSTEM TELEMETRY -- adapter, formatting,
    // badge/version-line/system-panel builders, and the SYSTEM disclosure
    // toggle. See fleet-monitor/server/public/lcars2/js/lcars-machine-health.js
    // (XACA-1092-003, do not modify) for the health-state derivation this
    // code wires up, and kanban/plans/XACA-1091/CONTRACT-system-block.md for
    // the frozen wire shape this adapter decouples from.
    //
    // Per XACA-1091-016 Design Decision 6, no shared helper was originally
    // extracted across the 5 createMachineItem copies -- that decision is now
    // PARTIALLY superseded: XACA-1100-002 extracted createMachineItem() itself
    // (the DOM-building renderer) into the shared lcars2 core
    // (lcars-fleet-core.js, LCARS.machines.createMachineItem, called with a
    // deps object above) because it was byte-identical across all 4 lcars2
    // app files with no lcars2-specific logic of its own. The REST of this
    // block -- the wire adapter, badge spec, system-panel-HTML builder, and
    // the SYSTEM disclosure toggle below -- is still duplicated identically in
    // all 4 lcars2 app files (byte-for-byte) and adapted (different
    // group/toggle class names, no data-* string interpolation -- see below)
    // in lcars-dashboard-app.js (v1); Design Decision 6 still applies to that
    // part unless/until a later ticket revisits it.
    // ============================================================================

    const SYSTEM_BYTES_PER_GB = 1024 * 1024 * 1024;

    // Wire adapter (XACA-1092-005): maps the frozen system{} contract onto
    // the normalized primitives deriveMachineHealth() expects. ALL wire-
    // format coupling lives here -- if the contract is revised, this is the
    // one place in this file that needs to change.
    //
    // Guards on the LEAF, never the container ('percent' in disk, not
    // `if (system.disk)`) -- system{}/disk{}/memory{}/versions{} all ship
    // as `{}` (truthy) rather than omitted when unresolvable (contract §3),
    // so a container-level truthiness check would treat every unresolved
    // machine as having real data. See XACA-1092-002 ADDENDUM.
    function machineSystemToHealthInput(system) {
        const sys = system || {};
        const disk = sys.disk || {};
        return {
            diskPercentUsed: ('percent' in disk) ? disk.percent : undefined,
            swapUsedBytes: ('swap_used_bytes' in sys) ? sys.swap_used_bytes : undefined,
            loadAvg1: (Array.isArray(sys.load_average) && sys.load_average.length > 0) ? sys.load_average[0] : undefined,
            coreCount: ('cores' in sys) ? sys.cores : undefined
        };
    }

    // Byte formatter -- a COLLECTED ZERO IS DATA (contract §3): renders as
    // the plain, non-italic "0 B", never "0.0 GB". Any non-finite-number
    // input (missing, null, or a hostile non-numeric value -- see the
    // HostileDefensive fixture case) returns null so the caller can render
    // the same "not reported" treatment absence gets, rather than a literal
    // "NaN GB" ever reaching the DOM. One decimal of precision (UX spec
    // §3): a rounded/lossy figure is what hid the real state in the
    // swap-percentage postmortem this spec cites.
    function formatSystemBytes(value) {
        if (typeof value !== 'number' || !isFinite(value)) {
            return null;
        }
        if (value === 0) {
            return '0 B';
        }
        return (value / SYSTEM_BYTES_PER_GB).toFixed(1) + ' GB';
    }

    function systemRowValue(label, valueHtml) {
        return '<div class="machine-system-row"><span class="machine-system-row-label">' + label + '</span>' +
            '<span class="machine-system-row-value">' + valueHtml + '</span></div>';
    }

    // UX spec §5: an omitted/unreportable leaf renders as a full muted word,
    // never a bare dash -- "a lone dash on a small row, sitting next to
    // numerals, is exactly the kind of subtle mark ... misread as part of a
    // number at a glance."
    function systemRowAbsent(label) {
        return '<div class="machine-system-row"><span class="machine-system-row-label">' + label + '</span>' +
            '<span class="machine-system-row-value machine-system-row-value-empty">not reported</span></div>';
    }

    function systemGroupHasAny(obj, keys) {
        const source = obj || {};
        for (let i = 0; i < keys.length; i++) {
            if (keys[i] in source) {
                return true;
            }
        }
        return false;
    }

    // PLATFORM group -- os_name/os_version/os_build combine into one OS row
    // per UX spec §3's worked example ("OS  macOS 27.0 (26A5388g)").
    // Reporter-supplied strings -> escapeHtml (element content), matching
    // this file's existing XACA-0416-004 convention for machine.hostname.
    function buildSystemOsRow(system) {
        const hasName = 'os_name' in system;
        const hasVersion = 'os_version' in system;
        const hasBuild = 'os_build' in system;
        if (!hasName && !hasVersion && !hasBuild) {
            return systemRowAbsent('OS');
        }
        let text = hasName ? escapeHtml(String(system.os_name)) : 'Unknown';
        if (hasVersion) {
            text += ' ' + escapeHtml(String(system.os_version));
        }
        if (hasBuild) {
            text += ' (' + escapeHtml(String(system.os_build)) + ')';
        }
        return systemRowValue('OS', text);
    }

    function buildPlatformGroupHtml(system) {
        if (!systemGroupHasAny(system, ['os_name', 'os_version', 'os_build', 'model', 'arch', 'cores'])) {
            return '';
        }
        let rows = buildSystemOsRow(system);
        rows += ('model' in system) ? systemRowValue('MODEL', escapeHtml(String(system.model))) : systemRowAbsent('MODEL');
        rows += ('arch' in system) ? systemRowValue('ARCH', escapeHtml(String(system.arch))) : systemRowAbsent('ARCH');
        // XACA-1092-017: system.cores is normally a number, but the reporter
        // contract does not enforce that at the wire boundary, so escapeHtml()
        // stays here as defense-in-depth rather than relying on typeof --
        // same reasoning applies to memory.pressure_percent and disk.percent
        // below.
        rows += ('cores' in system) ? systemRowValue('CORES', escapeHtml(String(system.cores))) : systemRowAbsent('CORES');
        return '<div class="status-row-system-group"><div class="machine-system-group-label">PLATFORM</div>' + rows + '</div>';
    }

    // MEMORY & SWAP group. memory.used/total combine into one MEMORY row;
    // swap_used_bytes (sibling of `memory`, NOT nested in it -- contract §1)
    // is its own row. NEVER a percentage -- see lcars-machine-health.js
    // module header ("DISK vs SWAP -- INVERSE RULES").
    function buildMemorySwapGroupHtml(system) {
        const memory = system.memory || {};
        const hasMemory = systemGroupHasAny(memory, ['used', 'total', 'pressure_percent']);
        const hasSwap = 'swap_used_bytes' in system;
        if (!hasMemory && !hasSwap) {
            return '';
        }

        let memoryRowHtml;
        if (!hasMemory) {
            memoryRowHtml = systemRowAbsent('MEMORY');
        } else {
            const usedStr = formatSystemBytes(memory.used);
            const totalStr = formatSystemBytes(memory.total);
            let text = (usedStr !== null ? usedStr : 'not reported') + ' / ' + (totalStr !== null ? totalStr : 'not reported');
            if ('pressure_percent' in memory) {
                // XACA-1092-017: normally numeric, escaped defensively --
                // see the comment on CORES in buildPlatformGroupHtml().
                text += '&nbsp;&nbsp;(' + escapeHtml(String(memory.pressure_percent)) + '% pressure)';
            }
            memoryRowHtml = systemRowValue('MEMORY', text);
        }

        let swapRowHtml;
        if (!hasSwap) {
            swapRowHtml = systemRowAbsent('SWAP');
        } else {
            const swapStr = formatSystemBytes(system.swap_used_bytes);
            swapRowHtml = systemRowValue('SWAP', swapStr !== null ? swapStr : 'not reported');
        }

        return '<div class="status-row-system-group"><div class="machine-system-group-label">MEMORY &amp; SWAP</div>' + memoryRowHtml + swapRowHtml + '</div>';
    }

    // DISK group. `disk.percent` is rendered EXACTLY as sent -- NEVER
    // recomputed from used/free (contract §5a: APFS df total is not
    // used+free; see lcars-machine-health.js module header for the ~20x
    // under-report this would otherwise silently produce).
    function buildDiskGroupHtml(system) {
        const disk = system.disk || {};
        if (!systemGroupHasAny(disk, ['used', 'free', 'percent'])) {
            return '';
        }
        const usedStr = formatSystemBytes(disk.used);
        const usedRow = systemRowValue('USED', usedStr !== null ? usedStr : 'not reported');

        const freeStr = formatSystemBytes(disk.free);
        let freeText = freeStr !== null ? freeStr : 'not reported';
        if ('percent' in disk) {
            // XACA-1092-017: normally numeric, escaped defensively -- see
            // the comment on CORES in buildPlatformGroupHtml().
            freeText += '&nbsp;&nbsp;(' + escapeHtml(String(disk.percent)) + '%)';
        }
        const freeRow = systemRowValue('FREE', freeText);

        return '<div class="status-row-system-group"><div class="machine-system-group-label">DISK</div>' + usedRow + freeRow + '</div>';
    }

    // LOAD group. Shows the raw triple AND the 1-minute figure normalized
    // per core (UX spec §3: showing only the raw number "reads as a wildly
    // overloaded box" without the per-core context). Never applies a
    // threshold itself -- XACA-1092-003 owns that, and its two constants
    // are under user review; this function only formats whatever
    // load_average/cores the reporter sent.
    function buildLoadGroupHtml(system) {
        const load = system.load_average;
        if (!Array.isArray(load) || load.length === 0) {
            return '';
        }
        function fmtEntry(v) {
            return (typeof v === 'number' && isFinite(v)) ? v.toFixed(2) : '?';
        }
        const triple = fmtEntry(load[0]) + ' / ' + fmtEntry(load[1]) + ' / ' + fmtEntry(load[2]);

        let suffix = '';
        const cores = system.cores;
        if (typeof load[0] === 'number' && isFinite(load[0]) && typeof cores === 'number' && isFinite(cores) && cores > 0) {
            suffix = '&nbsp;&nbsp;(' + (load[0] / cores).toFixed(2) + '× per core)';
        }
        return '<div class="status-row-system-group"><div class="machine-system-group-label">LOAD</div>' +
            systemRowValue('1 / 5 / 15 MIN', triple + suffix) + '</div>';
    }

    // Version line (UX spec §6) -- ALWAYS visible when the reporter has told
    // us the installed version at all, independent of whether any health
    // group has data (this is what makes the VersionsOnlyDayOne fixture
    // case show a version line with zero SYSTEM groups). Three states, keyed
    // off `'outdated' in versions` via strict comparison against true/false,
    // never off the truthiness of `outdated` itself -- `false` (confirmed
    // current) must render differently from omitted (unknown), and a
    // hostile non-boolean value (e.g. the string "yes") must fall safely
    // into the "unknown" bucket rather than matching either branch.

    // HEALTH badge (UX spec §4 + ADDENDUM): shown ONLY for 'at_risk' --
    // 'healthy' and 'unknown' both render as NO badge (not the same fact,
    // but the same silence -- see the ADDENDUM's "why not show unknown").
    // deriveMachineHealth()'s overall state collapses warning+critical into
    // a single 'at_risk', so the CRITICAL/AT RISK text choice is this
    // renderer's own aggregation across the per-metric states, per the
    // spec's explicit precedence rule ("if any metric is CRITICAL, show
    // CRITICAL; else if any is WARNING, show AT RISK").
    // Returns null when no badge should render, else {className, text}.
    // Deliberately a SPEC rather than an HTML string: the badge is appended
    // with the DOM API after XACA-1031-018's versionEl is in place, because
    // extending item.innerHTML at that point would destroy versionEl.
    function healthBadgeSpec(healthResult) {
        if (!healthResult || healthResult.state !== 'at_risk') {
            return null;
        }
        const metrics = healthResult.metrics || {};
        const anyCritical = ['disk', 'swap', 'load'].some(function (key) {
            return metrics[key] && metrics[key].state === 'critical';
        });
        return anyCritical
            ? { className: 'status-badge health-critical', text: 'CRITICAL' }
            : { className: 'status-badge health-warning', text: 'AT RISK' };
    }

    // VERSION badge -- shown ONLY for outdated === true (UX spec §4): never
    // for false (confirmed current) or omitted (unknown), both of which are
    // non-actionable at a glance and are differentiated instead on the
    // always-visible version line.

    // SYSTEM disclosure toggle + panel, or the static NO DATA line, or
    // nothing -- UX spec §5's "two-tier presence signal":
    //   - no `schema_version` at all (whole block absent, pre-XACA-1031
    //     reporter) -> '' (nothing new, matches today's card exactly)
    //   - `schema_version` present but zero health groups have any field
    //     (the VersionsOnlyDayOne/NonMacOSHostVersionsOnly shape -- the
    //     default production state for the entire window between XACA-1031
    //     merging and XACA-1091 shipping, per XACA-1091-016's fixture note
    //     "why case 9 is the most important one, not a rare edge") -> the
    //     static "SYSTEM: NO DATA REPORTED" line, no chevron
    //   - at least one group has at least one field -> the real interactive
    //     toggle + panel
    // Deliberately does NOT embed machine_id into this returned HTML string
    // -- the toggle's data-machine-id is set via el.setAttribute() by the
    // caller instead (an imperative DOM call, never HTML-string
    // interpolation), so this file's existing "no untrusted value reaches a
    // quoted attribute" invariant (XACA-0416-004) holds and escapeAttr()
    // stays undefined here, matching the rest of this file.
    function buildSystemSectionHtml(system, isExpanded) {
        const groupsHtml = buildPlatformGroupHtml(system) + buildMemorySwapGroupHtml(system) +
            buildDiskGroupHtml(system) + buildLoadGroupHtml(system);

        if (groupsHtml !== '') {
            return (
                '<div class="status-row-system-toggle clickable">' +
                    '<span class="status-row-system-indicator' + (isExpanded ? ' expanded' : '') + '">▶</span>' +
                    '<span class="status-row-system-label">SYSTEM</span>' +
                '</div>' +
                '<div class="status-row-system-panel' + (isExpanded ? ' expanded' : '') + '">' + groupsHtml + '</div>'
            );
        }

        if ('schema_version' in system) {
            return '<div class="status-row-system-no-data">SYSTEM: NO DATA REPORTED</div>';
        }

        return '';
    }

    function toggleSystemPanel(machineId, detailEl) {
        const panel = detailEl.querySelector('.status-row-system-panel');
        const indicator = detailEl.querySelector('.status-row-system-indicator');
        // XACA-1092-021 (WCAG 2.1.1): aria-expanded must track the SAME
        // state transitions as the `.expanded` class below -- the "close
        // myself" early-return path AND the "close whatever else was open"
        // side-effect path -- or a stale aria-expanded becomes worse than
        // none (a screen reader announcing "collapsed" on a panel that is
        // visibly open, or vice versa).
        const toggle = detailEl.querySelector('.status-row-system-toggle');
        if (!panel) return;

        if (expandedSystemMachineId === machineId) {
            expandedSystemMachineId = null;
            panel.classList.remove('expanded');
            if (indicator) indicator.classList.remove('expanded');
            if (toggle) toggle.setAttribute('aria-expanded', 'false');
            return;
        }

        if (expandedSystemMachineId) {
            const prevToggle = document.querySelector('.status-row-system-toggle[data-machine-id="' + CSS.escape(expandedSystemMachineId) + '"]');
            if (prevToggle) {
                const prevDetail = prevToggle.parentElement;
                const prevPanel = prevDetail ? prevDetail.querySelector('.status-row-system-panel') : null;
                const prevIndicator = prevDetail ? prevDetail.querySelector('.status-row-system-indicator') : null;
                if (prevPanel) prevPanel.classList.remove('expanded');
                if (prevIndicator) prevIndicator.classList.remove('expanded');
                prevToggle.setAttribute('aria-expanded', 'false');
            }
        }

        expandedSystemMachineId = machineId;
        panel.classList.add('expanded');
        if (indicator) indicator.classList.add('expanded');
        if (toggle) toggle.setAttribute('aria-expanded', 'true');
    }

    // ============================================================================
    // DIVISION MAPPINGS
    // ============================================================================

    function getDivisionTitle(divisionCode) {
        const code = divisionCode.toLowerCase();
        const titles = {
            'academy': 'STARFLEET ACADEMY',
            'android': 'ANDROID - STAR TREK: TOS',
            'command': 'STARFLEET COMMAND',
            'dns': 'DNS FRAMEWORK - STAR TREK: LOWER DECKS',
            'firebase': 'FIREBASE - STAR TREK: DS9',
            'freelance': 'FREELANCE - STAR TREK: ENT',
            'ios': 'IOS - STAR TREK: TNG',
            'legal': 'COPARENTING',
            'legal-coparenting': 'COPARENTING'
        };
        // Fallback for any legal-* variant
        if (!titles[code] && code.startsWith('legal')) {
            const suffix = code.replace('legal-', '').toUpperCase();
            return suffix || 'LEGAL';
        }
        return titles[code] || code.toUpperCase();
    }

    function getOrganizationGroup(divisionCode) {
        // Delegates to THE single implementation (XACA-0970):
        //   shared/js/lcars-org-resolution.js
        //
        // Do NOT reintroduce a local copy. This function previously existed in
        // FOURTEEN files across multiple variants -- and the only copy that handled
        // `finance` lived in a file no page loaded, so the bug looked fixed and
        // never ran. Add teams in the shared module, nowhere else.
        if (!window.LCARS_ORG) {
            // Loud on purpose: a missing module must not masquerade as a team
            // with no organization, which is the exact silent failure this
            // ticket exists to remove. Check script order in the page.
            console.error('[LCARS][org] shared/js/lcars-org-resolution.js is not '
                + 'loaded -- it must appear BEFORE this script. Falling back to UNKNOWN.');
            return 'UNKNOWN';
        }
        var cfg = (typeof teamConfig !== 'undefined') ? teamConfig : null;
        return window.LCARS_ORG.resolve(divisionCode, cfg);
    }

    function getGroupColor(group) {
        // Delegates to the shared module (XACA-0970), same as
        // getOrganizationGroup above. FINANCE was missing from every one of
        // the 14 copies of this map, so the org this ticket exists to surface
        // would have rendered with a fallback colour instead of its own.
        if (!window.LCARS_ORG) {
            console.error('[LCARS][org] shared/js/lcars-org-resolution.js is not '
                + 'loaded -- it must appear BEFORE this script.');
            // XACA-1110 design decision B1: this guard returned the literal
            // 'org-academy' identically in all four pre-unification files
            // (never CONFIG.unmappedOrgColor below), so DoubleNode/Main
            // Event/All-Fleet all silently mis-colored as Academy on this
            // failure path. PRESERVED VERBATIM here -- fixing it changes
            // observable behavior on doublenode/mainevent inside a
            // behavior-preserving refactor and would defeat the
            // differential harness's identity proof. Known-divergent,
            // tracked by XACA-1116 -- do not "fix" this as an oversight.
            return 'org-academy';
        }
        // D3: unmappedOrgColor is ALWAYS passed -- resolveColor's own `||`
        // chain already defaults to 'org-academy' when omitted, so academy
        // and 'all' (whose config sets the same default explicitly) are
        // unaffected; doublenode/mainevent override it via their own config.
        return window.LCARS_ORG.resolveColor(group, CONFIG.unmappedOrgColor);
    }

    // D2: adopted VERBATIM from the former lcars-all-app.js -- proven
    // equivalent to the static three-file version when teamConfig === null
    // (every filtered dashboard, forever): the prefix fallback below
    // returns 100 for freelance-*/legal-* codes, and the static map's own
    // `|| 100` default returns 100 for the exact same codes. No seam, no
    // branch -- see design decision doc D2 for the full proof.
    function getDivisionPriority(divisionCode) {
        const code = divisionCode.toLowerCase();

        // Check dynamic team config first (auto-discovered from board files)
        if (teamConfig && teamConfig.teams && teamConfig.teams[code]) {
            return teamConfig.teams[code].priority || 100;
        }

        // Fallback: Handle freelance-* and legal-* divisions
        if (code.startsWith('freelance') || code.startsWith('legal')) {
            return 100;
        }
        // Fallback: Static mapping for backward compatibility
        const priorities = {
            'command': 1,
            'android': 2,
            'firebase': 3,
            'ios': 4,
            'academy': 100,
            'dns': 100,
            'freelance': 100,
            'legal': 100,
            'legal-coparenting': 100
        };
        return priorities[code] || 100;
    }

    // ============================================================================
    // UTILITY FUNCTIONS
    // ============================================================================

    // XACA-0990: extracted to shared/js/lcars-terminal-card.js. This shim
    // preserves the local call site verbatim. Unlike createServiceOnlyLcarsCard
    // below, isLcarsTerminal takes no injected dependencies -- it has no
    // escapeHtml (or any other) callback to thread through.
    function isLcarsTerminal(teamData) {
        return LCARS_TERMINAL_CARD.isLcarsTerminal(teamData);
    }

    function getLcarsUrl(teamData) {
        if (!teamData) {
            return null;
        }

        const lcarsSession = teamData.sessions && teamData.sessions.find(function(session) {
            return session.name && session.name.toLowerCase().includes('lcars');
        });

        if (lcarsSession) {
            const localPort = lcarsSession.lcars_port || LCARS_PORT;

            if (!lcarsSession.hostname) {
                console.warn('No hostname reported for LCARS session on port ' + localPort);
                return null;
            }

            return 'http://' + lcarsSession.hostname + ':' + localPort;
        }

        // No session -- fall back to the reported service record directly
        // (XACA-0983 fix (b)).
        if (teamData.lcars_service && teamData.lcars_service.hostname) {
            return 'http://' + teamData.lcars_service.hostname + ':' + teamData.lcars_service.port;
        }

        return null;
    }

    function updateElement(id, value) {
        const el = document.getElementById(id);
        if (el) el.textContent = value;
    }

    function updateStardate() {
        const now = new Date();
        const year = now.getFullYear();
        const start = new Date(year, 0, 0);
        const diff = now - start;
        const oneDay = 1000 * 60 * 60 * 24;
        const dayOfYear = Math.floor(diff / oneDay);

        const stardate = CONFIG.stardateOffset + (year - 2024) * 1000 + (dayOfYear / 365 * 1000);
        updateElement('stardate', stardate.toFixed(1));
    }

    function formatTimestamp(timestamp) {
        if (!timestamp) return '--:--:--';

        const date = new Date(timestamp);
        const hours = String(date.getHours()).padStart(2, '0');
        const minutes = String(date.getMinutes()).padStart(2, '0');
        const seconds = String(date.getSeconds()).padStart(2, '0');

        return hours + ':' + minutes + ':' + seconds;
    }

    function updateConnectionStatus(connected) {
        const statusText = document.getElementById('connection-status');
        const statusIndicator = document.getElementById('connection-indicator');

        if (connected) {
            if (statusText) statusText.textContent = 'MONITORING ACTIVE';
            if (statusIndicator) statusIndicator.className = 'status-indicator online';
        } else {
            if (statusText) statusText.textContent = 'CONNECTION LOST';
            if (statusIndicator) statusIndicator.className = 'status-indicator offline';
        }
    }

    // ============================================================================
    // CLEANUP
    // ============================================================================

    window.addEventListener('beforeunload', function() {
        if (refreshTimer) {
            clearInterval(refreshTimer);
        }
    });

})();
