//
//  lcars-dashboard-app.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * LCARS Unified Dashboard Application
 * Dynamic dashboard loading from URL parameter
 *
 * Usage: lcars-dashboard.html?dashboard=academy
 * Default: academy (if no parameter)
 */

(function() {
    'use strict';

    // ============================================================================
    // CONFIGURATION
    // ============================================================================

    const CONFIG = {
        apiBase: window.location.origin,
        refreshInterval: 60000,
        stardateOffset: 41000,
        divisions: null,        // Will be set from dashboard config
        machines: null,         // Will be set from dashboard config
        dashboardId: 'academy', // Default dashboard
        dashboardName: 'ACADEMY',
        emptyMessage: 'No active divisions detected'
    };

    // Current dashboard config (loaded from API)
    let dashboardConfig = null;
    let allDashboards = [];  // Cache all dashboards for sidebar

    const LCARS_PORT = 8080;

    // ============================================================================
    // STATE
    // ============================================================================

    let fleetData = null;
    let refreshTimer = null;
    let lastSeenTimer = null;
    let cachedMachineData = null;
    let cachedDivisions = null;
    let expandedMachineId = null;
    let expandedBackupMachineId = null;
    let backupStatus = null;
    let workingItems = null;
    let teamConfig = null;
    let divisionToTeamMap = {};  // Maps fleet division keys to registered team keys

    // XACA-1060: MACHINES filter bar state. Plain object used as a set of
    // DISABLED hostnames (mirrors the object-as-set idiom in getTeamHosts()
    // below). renderDivisions() does `container.innerHTML = ''` on EVERY
    // poll, so this state cannot live in the DOM -- it has to survive here,
    // at module scope, across render passes. Empty object == everything
    // shown: defaulting to "empty means all on" is deliberate, so a machine
    // that appears for the first time between polls is shown by default
    // rather than silently hidden.
    //
    // A hostname disabled here that later drops out of fleet.machines[]
    // (machine goes offline / deregisters) is intentionally left in place
    // rather than pruned -- there's just no nav button to click until that
    // machine reappears, at which point the user's earlier choice is
    // honored again instead of silently reset.
    // XACA-1060: Object.create(null), NOT {} -- `hostname` is copied verbatim
    // from reporter payloads (same untrusted-input class as the `organization`
    // field XACA-0970 had to fix), so a machine legitimately or maliciously
    // named 'toString', 'constructor' or 'valueOf' would hit Object.prototype
    // on a plain-object lookup and read back TRUTHY while never having been
    // toggled -- permanently hiding that machine's cards with no way to
    // un-hide them (the toggle's `delete` on an inherited key is a no-op, so
    // it would latch). A null-prototype map has no inherited keys at all.
    let machineFilterState = Object.create(null);

    // ============================================================================
    // INITIALIZATION
    // ============================================================================

    document.addEventListener('DOMContentLoaded', async function() {
        console.log('[LCARS] Unified Dashboard initializing...');

        // Get dashboard ID from URL parameter (default to 'academy')
        const urlParams = new URLSearchParams(window.location.search);
        CONFIG.dashboardId = urlParams.get('dashboard') || 'academy';

        console.log('[LCARS] Loading dashboard:', CONFIG.dashboardId);

        // Load dashboard configuration FIRST
        await loadDashboardConfig();

        // Initialize Analytics Pages (sub-screen navigation for analytics section)
        if (window.LCARSAnalyticsPages) {
            LCARSAnalyticsPages.init({
                divisions: CONFIG.divisions,
                dashboardId: CONFIG.dashboardId
            });
        }

        // Configure kanban analytics with dashboard division filter
        if (window.LCARSAnalyticsKanban && LCARSAnalyticsKanban.setDivisions) {
            LCARSAnalyticsKanban.setDivisions(CONFIG.divisions);
        }

        // Configure knowledge analytics with dashboard division filter
        if (window.LCARSAnalyticsKnowledge && LCARSAnalyticsKnowledge.setDivisions) {
            LCARSAnalyticsKnowledge.setDivisions(CONFIG.divisions);
        }

        // Initialize LCARS core
        if (window.LCARS_CORE) {
            LCARS_CORE.init({
                candyOptions: { section: 'overview' }
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

        // Fetch team configuration for avatar/org mapping
        await fetchTeamConfig();

        // Initial data fetch
        fetchFleetData();

        // Load dashboard links dynamically
        loadDashboardLinks();

        // Set up auto-refresh
        refreshTimer = setInterval(fetchFleetData, CONFIG.refreshInterval);

        // Update stardate
        updateStardate();
        setInterval(updateStardate, 1000);

        // Start "Last:" timer
        startLastSeenTimer();

        // Listen for refresh events
        document.addEventListener('lcars:refresh', function() {
            fetchFleetData();
        });

        // Listen for section change events to initialize admin panel
        document.addEventListener('lcars:sectionChange', function(e) {
            if (e.detail && e.detail.section === 'admin') {
                initDashboardsAdmin();
            }
        });

        // Listen for dashboard changes (e.g., reorder) to refresh sidebar links
        document.addEventListener('lcars:dashboardsChanged', function() {
            console.log('[LCARS] Dashboards changed, refreshing sidebar links...');
            loadDashboardLinks();
        });

        console.log('[LCARS] Unified Dashboard initialized');
    });

    // ============================================================================
    // DASHBOARD CONFIGURATION LOADING
    // ============================================================================

    /**
     * Load dashboard configuration from API and apply it to the page
     */
    async function loadDashboardConfig() {
        try {
            const response = await fetch(CONFIG.apiBase + '/api/dashboards/' + CONFIG.dashboardId);
            if (!response.ok) {
                console.warn('[LCARS] Dashboard not found, using defaults');
                return;
            }

            dashboardConfig = await response.json();
            console.log('[LCARS] Dashboard config loaded:', dashboardConfig);

            // Apply configuration
            applyDashboardConfig(dashboardConfig);

        } catch (error) {
            console.error('[LCARS] Failed to load dashboard config:', error);
        }
    }

    /**
     * Apply dashboard configuration to the page
     */
    function applyDashboardConfig(config) {
        // Set CONFIG values
        CONFIG.dashboardName = config.name || 'DASHBOARD';
        CONFIG.divisions = (config.divisions && config.divisions.length > 0) ? config.divisions : null;
        CONFIG.machines = (config.machines && config.machines.length > 0) ? config.machines : null;

        // Apply org color class to body
        const orgColor = config.org_color || 'lavender';
        document.body.className = 'org-color-' + orgColor;

        // Update page title
        document.title = 'LCARS - ' + config.name + ' Operations';

        // Update startup text
        const startupTitle = document.getElementById('startup-title');
        const startupSubtitle = document.getElementById('startup-subtitle');
        if (startupTitle) startupTitle.textContent = config.title || config.name.toUpperCase();
        if (startupSubtitle) startupSubtitle.textContent = config.subtitle || 'OPERATIONS MONITOR';

        // Update group-id
        const groupId = document.getElementById('group-id');
        if (groupId) groupId.textContent = config.name.toUpperCase();

        // Update title elements
        const titleFull = document.getElementById('title-full');
        const titleMedium = document.getElementById('title-medium');
        const titleShort = document.getElementById('title-short');
        if (titleFull) titleFull.textContent = (config.title || config.name.toUpperCase()) + ' OPERATIONS';
        if (titleMedium) titleMedium.textContent = config.name.toUpperCase() + ' OPS';
        if (titleShort) titleShort.textContent = config.name.toUpperCase();

        // Show/hide the ADMIN pill (only for the 'all' dashboard).
        // XACA-0963 moved it from the vertical sidebar into the top utility bar;
        // the ALL-FLEET-only rule is unchanged, only the element moved.
        const adminBtn = document.querySelector('.admin-pill');
        if (adminBtn) {
            adminBtn.style.display = (CONFIG.dashboardId === 'all') ? '' : 'none';
        }
        // No bottom-border transfer here: ENGINES sits below ADMIN, is always
        // visible, and owns the terminating black bar in CSS. Transferring the
        // border to SETTINGS (as this did) drew it in the middle of the stack.

        // If not on 'all' dashboard and ADMIN section would be shown, switch to OVERVIEW
        if (CONFIG.dashboardId !== 'all') {
            // Check if saved section in localStorage is 'admin'
            const savedSection = localStorage.getItem('lcars-section');
            if (savedSection === 'admin') {
                // Clear it so LCARS_CORE doesn't try to load admin
                localStorage.setItem('lcars-section', 'overview');
            }

            // Also switch section if already initialized and on admin
            if (window.LCARS_CORE && LCARS_CORE.sections && LCARS_CORE.state && LCARS_CORE.state.currentSection === 'admin') {
                LCARS_CORE.sections.switchSection('overview');
            }
        }

        // Populate dashboard dropdown in settings
        populateDashboardDropdown();
    }

    /**
     * Populate the dashboard dropdown in settings
     * Filters based on visible_dashboards config (same logic as sidebar)
     */
    function populateDashboardDropdown() {
        const select = document.getElementById('dashboard-select');
        if (!select || allDashboards.length === 0) return;

        // Find current dashboard and ALL FLEET dashboard for visibility settings
        const currentDashboard = allDashboards.find(d => d.id === CONFIG.dashboardId);
        const allFleetDashboard = allDashboards.find(d => d.id === 'all');
        const showAllFleetOn = allFleetDashboard ? (allFleetDashboard.show_all_fleet_on || []) : [];
        const visibleDashboards = currentDashboard ? currentDashboard.visible_dashboards : null;

        // Filter dashboards to show (same logic as sidebar)
        const dashboardsToShow = allDashboards.filter(function(d) {
            // Always show the current dashboard
            if (d.id === CONFIG.dashboardId) return true;

            // If current dashboard has visible_dashboards defined, use it
            if (visibleDashboards && Array.isArray(visibleDashboards)) {
                return visibleDashboards.includes(d.id);
            }

            // Default behavior: handle 'all' dashboard visibility via show_all_fleet_on
            if (d.id === 'all') {
                return CONFIG.dashboardId === 'all' || showAllFleetOn.includes(CONFIG.dashboardId);
            }

            // Show all other dashboards by default
            return true;
        });

        select.innerHTML = dashboardsToShow.map(function(d) {
            const selected = d.id === CONFIG.dashboardId ? ' selected' : '';
            // XACA-0416 (review finding 1): d.id and d.name come from
            // POST /api/dashboards, which sits on the SAME requireApiKey tier as
            // /api/team-register and stores these with presence-only validation --
            // so they are exactly as untrusted as the session.* fields this ticket
            // already escapes. d.id lands in a QUOTED ATTRIBUTE that is also a URL
            // query parameter: encodeURIComponent first (correct for the URL layer,
            // and the identity function for the slug-shaped ids in use), then
            // escapeAttr for the attribute layer -- escapeHtml would be a false fix
            // here because it leaves `"` untouched. d.name is ELEMENT CONTENT ->
            // escapeHtml. String(d.name || '') because .toUpperCase() on a missing
            // name would throw and blank the whole dropdown.
            return '<option value="lcars-dashboard.html?dashboard=' + escapeAttr(encodeURIComponent(d.id)) + '"' + selected + '>' + escapeHtml(String(d.name || '').toUpperCase()) + '</option>';
        }).join('');

        select.onchange = function() {
            window.location.href = this.value;
        };
    }

    // ============================================================================
    // DATA FETCHING
    // ============================================================================

    async function fetchFleetData() {
        try {
            const response = await fetch(CONFIG.apiBase + '/api/fleet');
            if (!response.ok) {
                throw new Error('HTTP ' + response.status + ': ' + response.statusText);
            }
            fleetData = await response.json();
            await Promise.all([fetchBackupStatus(), fetchWorkingItems()]);
            const filteredData = filterData(fleetData);
            renderDashboard(filteredData);
            updateConnectionStatus(true);

            // Refresh analytics charts when analytics section is active.
            // The analytics modules self-initialize on section switch but have no
            // internal timer — so the main refresh cycle is responsible for keeping
            // them current. Only call refresh() when analytics is visible to avoid
            // unnecessary API calls on other sections.
            const activeSection = window.LCARS_CORE && LCARS_CORE.sections && LCARS_CORE.sections.active;
            if (activeSection === 'analytics') {
                if (typeof LCARSAnalyticsKanban !== 'undefined') {
                    LCARSAnalyticsKanban.refresh();
                }
                if (typeof LCARSAnalyticsFleet !== 'undefined') {
                    LCARSAnalyticsFleet.refresh();
                }
                if (typeof LCARSAnalyticsKnowledge !== 'undefined') {
                    LCARSAnalyticsKnowledge.refresh();
                }
            }
        } catch (error) {
            console.error('[LCARS] Failed to fetch fleet data:', error);
            updateConnectionStatus(false);
        }
    }

    async function fetchBackupStatus() {
        try {
            const response = await fetch(CONFIG.apiBase + '/api/backup-status');
            if (response.ok) {
                backupStatus = await response.json();
            }
        } catch (error) {
            console.log('[LCARS] Could not fetch backup status:', error);
            backupStatus = null;
        }
    }

    async function fetchWorkingItems() {
        try {
            const response = await fetch(CONFIG.apiBase + '/api/working-items');
            if (response.ok) {
                workingItems = await response.json();
            }
        } catch (error) {
            console.log('[LCARS] Could not fetch working items:', error);
            workingItems = null;
        }
    }

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
                buildDivisionToTeamMap();
            }
        } catch (error) {
            console.warn('[LCARS] Could not fetch team config, using defaults:', error.message);
        }
    }

    /**
     * Build mapping from fleet division keys to registered team keys.
     * Handles naming mismatches:
     *   fleet "freelance-starwords" → registered "freelance-doublenode-starwords"
     *   fleet "legal" → registered "legal-coparenting"
     *   fleet "medical" → registered "medical-general"
     */
    function buildDivisionToTeamMap() {
        divisionToTeamMap = {};
        if (!teamConfig || !teamConfig.teams) return;

        for (var teamId in teamConfig.teams) {
            // Direct mapping: teamId IS the division key for simple cases
            divisionToTeamMap[teamId] = teamId;

            // freelance-doublenode-X → also map freelance-X
            if (teamId.indexOf('freelance-doublenode-') === 0) {
                var suffix = teamId.replace('freelance-doublenode-', '');
                divisionToTeamMap['freelance-' + suffix] = teamId;
            }
            // legal-X → also map "legal" (single project)
            else if (teamId.indexOf('legal-') === 0) {
                divisionToTeamMap['legal'] = teamId;
            }
            // medical-X → also map "medical" (single project)
            else if (teamId.indexOf('medical-') === 0) {
                divisionToTeamMap['medical'] = teamId;
            }
        }
        console.log('[LCARS] Division-to-team map built:', Object.keys(divisionToTeamMap).length, 'mappings');
    }

    function filterData(data) {
        if (!data || !data.fleet) return data;

        // If no division filter AND no machine filter, return data as-is
        if (!CONFIG.divisions && !CONFIG.machines) {
            return data;
        }

        const fleet = data.fleet;
        const filteredDivisions = {};
        let filteredTotalSessions = 0;

        // Filter by divisions if configured
        for (const divisionName in fleet.divisions || {}) {
            // If divisions filter is set, check if this division is included
            if (CONFIG.divisions && !CONFIG.divisions.includes(divisionName.toLowerCase())) {
                continue;
            }
            filteredDivisions[divisionName] = fleet.divisions[divisionName];
            filteredTotalSessions += fleet.divisions[divisionName].total_sessions || 0;
        }

        // Filter machines
        let filteredMachines = (fleet.machines || []).map(function(machine) {
            let filteredSessions = machine.sessions || [];

            // Filter sessions by division if configured
            if (CONFIG.divisions) {
                filteredSessions = filteredSessions.filter(function(session) {
                    return CONFIG.divisions.includes((session.division || '').toLowerCase());
                });
            }

            return Object.assign({}, machine, {
                sessions: filteredSessions,
                session_count: filteredSessions.length
            });
        });

        // Filter by machine IDs if configured
        if (CONFIG.machines) {
            filteredMachines = filteredMachines.filter(function(machine) {
                return CONFIG.machines.includes(machine.machine_id);
            });
        }

        // Remove machines with no sessions (after filtering)
        filteredMachines = filteredMachines.filter(function(machine) {
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
            last_update: data.last_update,
            activityLog: data.activityLog
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

        // Cache machine data
        cachedMachineData = fleet.machines || [];
        cachedDivisions = fleet.divisions;

        // Render each section independently so one failure doesn't block others
        try { renderDivisions(fleet.divisions); }
        catch (e) { console.error('[LCARS] renderDivisions error:', e); }

        try { renderMachines(fleet.machines); }
        catch (e) { console.error('[LCARS] renderMachines error:', e); }

        try { renderActivityLog(data.activityLog || []); }
        catch (e) { console.error('[LCARS] renderActivityLog error:', e); }
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
                if (window.LCARS_CORE && LCARS_CORE.sections) {
                    LCARS_CORE.sections.switchSection('organizations');
                }
                setTimeout(function() {
                    const targetId = 'org-' + orgName.toLowerCase().replace(/\s+/g, '-');
                    const targetElement = document.getElementById(targetId);
                    if (targetElement) {
                        targetElement.scrollIntoView({ behavior: 'smooth', block: 'start' });
                    }
                }, 150);
            };

            navContainer.appendChild(navButton);
        });
    }

    // XACA-1062: given a machine's last-reported `status`, returns the
    // human-readable status word used in both the stat line and the
    // aria-label. 'warning' is a real third status (a machine that IS
    // still reporting but flagged degraded) and must never collapse into
    // 'offline' -- see the XACA-1062 plan doc's "warning is not offline"
    // design note. Any status this build doesn't recognize falls back to
    // 'Offline' (fail toward "treat the count as stale", not toward
    // "assume the machine is fine").
    function machineStatusLabel(status) {
        switch (status) {
            case 'online': return 'Online';
            case 'warning': return 'Warning';
            default: return 'Offline';
        }
    }

    // XACA-1062: single source of truth for the MACHINES nav button's stat
    // text, called from BOTH renderMachineFilterNav() (first paint) and
    // updateMachineNavStats() (every applyMachineFilter() pass) so the two
    // sites can never disagree. `cardCount` is the number of rendered
    // '.team-card[data-machine-host]' nodes for this host -- meaningful
    // only for an ONLINE machine, since the server excludes non-online
    // machines' sessions from the `divisions` tree entirely, so a
    // non-online machine's cardCount is always 0 regardless of how many
    // sessions it actually has (that's the bug this ticket fixes -- see
    // plan doc Summary). For a non-online machine we show the LAST-KNOWN
    // session_count instead, but always paired with the status word:
    // session_count on the machine record is what that machine last
    // reported, not what's currently on screen, and showing it bare would
    // just trade one misleading number ("0 Teams") for another (a stale
    // count presented as if it were live).
    function machineNavStatText(status, sessionCount, cardCount) {
        if (status === 'online') {
            return cardCount + (cardCount === 1 ? ' Team' : ' Teams');
        }
        const count = sessionCount || 0;
        return machineStatusLabel(status).toUpperCase() + ' · ' + count;
    }

    // XACA-1062: aria-label text for the MACHINES nav button. Sighted users
    // get the status from the stat line's text/colour (see XACA-1062-002
    // for the styling); without this, assistive tech only ever heard
    // "Toggle team cards for <name>" with no way to learn the machine is
    // offline (or warning) -- requirement 3 of the XACA-1062 plan doc.
    function machineNavAriaLabel(displayName, status, sessionCount) {
        const statusWord = machineStatusLabel(status);
        if (status === 'online') {
            return 'Toggle team cards for ' + displayName + ' (' + statusWord + ')';
        }
        const count = sessionCount || 0;
        return 'Toggle team cards for ' + displayName + ' (' + statusWord + ', last known ' +
            count + (count === 1 ? ' session' : ' sessions') + ')';
    }

    // XACA-1060: MACHINES filter bar. One multi-select toggle button per
    // fleet.machines[] entry, independent of the ORGANIZATIONS nav above
    // (that one is single-target scroll-to; this one show/hides team cards
    // in place). Built fresh every render pass -- like renderOrganizationNav,
    // it does not try to diff against the previous pass's buttons.
    function renderMachineFilterNav(machines) {
        const navContainer = document.getElementById('machine-nav');
        if (!navContainer) return;

        navContainer.innerHTML = '';

        const sortedMachines = (machines || []).slice().sort(function(a, b) {
            const nameA = (a.nickname || a.hostname || '').toLowerCase();
            const nameB = (b.nickname || b.hostname || '').toLowerCase();
            return nameA.localeCompare(nameB);
        });

        sortedMachines.forEach(function(machine) {
            const host = machine.hostname;
            if (!host) return; // nothing on a card could ever match this button

            const displayName = machine.nickname || machine.hostname;
            const isDisabled = !!machineFilterState[host];
            const status = machine.status || 'offline';
            const sessionCount = machine.session_count || 0;

            const navButton = document.createElement('button');
            navButton.type = 'button';
            navButton.className = 'machine-nav-button status-' + status + (isDisabled ? ' disabled' : '');
            navButton.dataset.machineHost = host;
            // XACA-1062: carried on the button because updateMachineNavStats()
            // is purely DOM-driven and has no access to fleet.machines[] --
            // stashing status/session_count here (rather than adding a second
            // module-scoped machine-data cache) is what lets that function
            // recompute the identical stat text/aria-label from this same
            // source of truth instead of a copy of it.
            navButton.dataset.machineStatus = status;
            navButton.dataset.machineSessionCount = String(sessionCount);
            navButton.setAttribute('aria-pressed', isDisabled ? 'false' : 'true');
            // setAttribute (not innerHTML) -- not a markup sink, so this is safe
            // even though displayName is untrusted (see textContent note below).
            navButton.setAttribute('aria-label', machineNavAriaLabel(displayName, status, sessionCount));

            // textContent, not innerHTML: hostname/nickname arrive from reporter
            // payloads, same untrusted-input class as the `organization` field
            // XACA-0970 had to fix in renderOrganizationNav above -- an
            // injection sink here would be the exact same bug in a new spot.
            const navName = document.createElement('span');
            navName.className = 'machine-nav-name';
            navName.textContent = displayName;
            navButton.appendChild(navName);

            const navStats = document.createElement('span');
            navStats.className = 'machine-nav-stats';
            // XACA-1060/XACA-1062: cardCount is always 0 here, not the real
            // number -- team cards for this poll haven't been created yet at
            // this call site (renderDivisions calls this BEFORE building
            // division panels, mirroring renderOrganizationNav's call site).
            // applyMachineFilter(), wired at the tail of renderDivisions
            // inside the SAME synchronous render pass (see endRenderPass()
            // below), calls updateMachineNavStats() to fill in the real
            // count before the browser ever gets a chance to paint this.
            // Routing through machineNavStatText() even at this placeholder
            // stage means a non-online machine's FIRST paint already reads
            // e.g. "OFFLINE · 44" instead of a "0 Teams" placeholder that
            // updateMachineNavStats() would otherwise have to overwrite a
            // moment later -- there is no placeholder text for that case.
            navStats.textContent = machineNavStatText(status, sessionCount, 0);
            navButton.appendChild(navStats);

            navButton.onclick = function() {
                toggleMachineFilter(host);
            };

            navContainer.appendChild(navButton);
        });
    }

    // XACA-1060: flips one host's membership in the disabled set and
    // re-applies the filter immediately -- no full renderDivisions() re-run,
    // since the cards/chips/panels already exist and only need hidden
    // toggled + stats recomputed.
    function toggleMachineFilter(hostname) {
        if (!hostname) return;
        if (machineFilterState[hostname]) {
            delete machineFilterState[hostname];
        } else {
            machineFilterState[hostname] = true;
        }
        applyMachineFilter();
    }

    // XACA-1060: refreshes each MACHINES nav button's disabled class,
    // aria-pressed, and live team-card count. The count is the TOTAL number
    // of team cards rendered for that host, independent of that host's own
    // filter state (so a filtered-off machine still shows an honest count of
    // what enabling it would reveal) -- but it does live under
    // #divisions-container, so it's still 0 for a poll where nothing has
    // rendered yet.
    function updateMachineNavStats() {
        const navContainer = document.getElementById('machine-nav');
        if (!navContainer) return;
        const divisionsContainer = document.getElementById('divisions-container');

        const buttons = navContainer.querySelectorAll('.machine-nav-button[data-machine-host]');
        for (let i = 0; i < buttons.length; i++) {
            const btn = buttons[i];
            const host = btn.dataset.machineHost;
            let count = 0;
            if (divisionsContainer) {
                const cards = divisionsContainer.querySelectorAll('.team-card[data-machine-host]');
                for (let c = 0; c < cards.length; c++) {
                    if (cards[c].dataset.machineHost === host) count++;
                }
            }
            // XACA-1062: this function is purely DOM-driven -- it has no
            // access to fleet.machines[] -- so status/session_count ride
            // along on the button's own dataset, stashed there by
            // renderMachineFilterNav() at first paint (see the comment on
            // that dataset assignment above). Reading them back here, rather
            // than keeping a second machine-data cache in sync with it, is
            // what keeps these two call sites from ever disagreeing.
            const status = btn.dataset.machineStatus || 'offline';
            const sessionCount = Number(btn.dataset.machineSessionCount) || 0;

            const statsEl = btn.querySelector('.machine-nav-stats');
            if (statsEl) {
                statsEl.textContent = machineNavStatText(status, sessionCount, count);
            }

            // aria-label refreshed alongside aria-pressed below -- same
            // reasoning as XACA-1060's existing aria-pressed refresh: this
            // function runs on every applyMachineFilter() pass, so a stale
            // aria-label from first paint would otherwise never update.
            const nameEl = btn.querySelector('.machine-nav-name');
            const displayName = nameEl ? nameEl.textContent : host;
            btn.setAttribute('aria-label', machineNavAriaLabel(displayName, status, sessionCount));

            const isDisabled = !!machineFilterState[host];
            btn.classList.toggle('disabled', isDisabled);
            btn.setAttribute('aria-pressed', isDisabled ? 'false' : 'true');
        }
    }

    // XACA-1060: applies machineFilterState to the already-rendered DOM.
    // Uses the `hidden` ATTRIBUTE, never style.display and never an ad-hoc
    // class -- wireDivisionToggle() in shared/js/lcars-division-collapse.js
    // (XACA-0989) already owns style.display on '.chip-row' and
    // '.teams-grid' themselves (the CONTAINERS), so this only ever sets
    // `hidden` on the individual CHILDREN of those containers (cards, chips,
    // avatar thumbs) plus the division/organization panels one level up.
    // Two different mechanisms on two different levels of the tree -- they
    // don't fight because neither one touches the element the other owns.
    function applyMachineFilter() {
        const divisionsContainer = document.getElementById('divisions-container');
        if (!divisionsContainer) return;

        // 1. Expanded-view team cards.
        const cards = divisionsContainer.querySelectorAll('.team-card[data-machine-host]');
        for (let i = 0; i < cards.length; i++) {
            cards[i].hidden = !!machineFilterState[cards[i].dataset.machineHost];
        }

        // 2. Collapsed-view chips -- same rule, so the chip row filters
        // identically to the expanded grid it stands in for.
        const chips = divisionsContainer.querySelectorAll('.chip-row > *[data-machine-host]');
        for (let j = 0; j < chips.length; j++) {
            chips[j].hidden = !!machineFilterState[chips[j].dataset.machineHost];
        }

        // 2b. Division avatar-grid thumbnails (XACA-1060-006) -- tagged with
        // the same per-host granularity as the card/chip split.
        const avatars = divisionsContainer.querySelectorAll('.org-avatar-thumb[data-machine-host]');
        for (let k = 0; k < avatars.length; k++) {
            avatars[k].hidden = !!machineFilterState[avatars[k].dataset.machineHost];
        }

        // 3. Division panels, hidden when their visible card count is zero --
        // and their filtered session-count stat recomputed to match. This is
        // a literal "zero visible cards -> hidden" rule: it also hides a
        // division whose only teams were hostless (already dropped from the
        // DOM entirely up in createDivisionPanel/splitTeamByHost) regardless
        // of whether the MACHINES filter is what caused it -- there's nothing
        // useful to show either way.
        const panels = divisionsContainer.querySelectorAll('.division-container');
        for (let p = 0; p < panels.length; p++) {
            const panel = panels[p];
            const panelCards = panel.querySelectorAll('.team-card[data-machine-host]');
            let visibleCardCount = 0;
            let visibleSessionCount = 0;
            for (let c2 = 0; c2 < panelCards.length; c2++) {
                if (!panelCards[c2].hidden) {
                    visibleCardCount++;
                    visibleSessionCount += parseInt(panelCards[c2].dataset.sessionCount, 10) || 0;
                }
            }
            panel.hidden = (visibleCardCount === 0);

            // Preserve '.division-toggle-icon': wireDivisionToggle() (XACA-0989)
            // requires that span to exist and writes the chevron glyph into it
            // every render pass. Rewrite only the dedicated
            // '.division-stats-count' text span added in createDivisionPanel
            // for exactly this purpose -- never '.division-stats.textContent',
            // which would delete the icon span and silently kill collapse.
            const statsCountEl = panel.querySelector('.division-stats-count');
            if (statsCountEl) {
                statsCountEl.textContent = visibleSessionCount + (visibleSessionCount === 1 ? ' Session' : ' Sessions');
            }
        }

        // 4. Organization panels, hidden when every division inside them is
        // hidden; count re-summed from the divisions' own (already-updated)
        // filtered stat above rather than re-walking data.projects.
        const orgPanels = divisionsContainer.querySelectorAll('.organization-panel');
        let visibleOrgPanelCount = 0;
        for (let o = 0; o < orgPanels.length; o++) {
            const orgPanel = orgPanels[o];
            const orgDivisions = orgPanel.querySelectorAll('.division-container');
            let visibleDivisionCount = 0;
            let orgVisibleSessions = 0;
            for (let d2 = 0; d2 < orgDivisions.length; d2++) {
                if (!orgDivisions[d2].hidden) {
                    visibleDivisionCount++;
                    const dCountEl = orgDivisions[d2].querySelector('.division-stats-count');
                    if (dCountEl) {
                        orgVisibleSessions += parseInt(dCountEl.textContent, 10) || 0;
                    }
                }
            }
            orgPanel.hidden = (visibleDivisionCount === 0);
            if (!orgPanel.hidden) visibleOrgPanelCount++;

            const orgCountEl = orgPanel.querySelector('.organization-count');
            if (orgCountEl) {
                orgCountEl.textContent = orgVisibleSessions + ' Sessions';
            }
        }

        // 4b. XACA-1060-017: when the MACHINES filter hides every org panel,
        // the container would otherwise go visually blank -- indistinguishable
        // from a broken page. This is deliberately a SEPARATE element/class
        // from CONFIG.emptyMessage's '.empty-message' (the "server sent zero
        // divisions" case in renderDivisions, which returns before this
        // function's body even runs and rebuilds no org panels at all) so the
        // two states are never confusable and never collide in the DOM.
        // Only relevant when there WERE org panels to filter -- an org-less
        // poll is already handled by renderDivisions' own empty-message path.
        // Re-derived every call (both the poll re-render tail call and the
        // per-click toggleMachineFilter() call), so it survives
        // renderDivisions() wiping '#divisions-container' each pass and never
        // leaves a stale message once a panel becomes visible again.
        let filterEmptyMessageEl = divisionsContainer.querySelector('.machine-filter-empty-message');
        if (orgPanels.length > 0 && visibleOrgPanelCount === 0) {
            if (!filterEmptyMessageEl) {
                filterEmptyMessageEl = document.createElement('p');
                filterEmptyMessageEl.className = 'empty-message machine-filter-empty-message';
                divisionsContainer.appendChild(filterEmptyMessageEl);
            }
            filterEmptyMessageEl.textContent = 'All machines filtered out — re-enable a machine above to see teams';
        } else if (filterEmptyMessageEl) {
            filterEmptyMessageEl.remove();
        }

        // 5. Nav button disabled class / aria-pressed / live team count.
        updateMachineNavStats();
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
        // XACA-1060: builds the MACHINES nav buttons themselves; their live
        // team counts are placeholders here (cards don't exist yet this
        // pass) and get filled in by applyMachineFilter() below, inside the
        // same synchronous pass, before this ever paints.
        renderMachineFilterNav(cachedMachineData);

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

        // XACA-1060: re-apply the MACHINES filter now that this pass's cards,
        // chips, and avatar thumbs all exist -- must run BEFORE endRenderPass()
        // reads the controllers array (division/organization panel `hidden`
        // state and the nav buttons' live counts all need to be correct
        // before that pass is considered final), but stays INSIDE the
        // beginRenderPass()/endRenderPass() bracket per XACA-0989-019: that
        // bracket must span the entire pass, not just the parts unrelated to
        // this feature.
        applyMachineFilter();

        // XACA-0989: refresh the Expand All / Collapse All label now that
        // this pass's division set (and each panel's initial paint) is final.
        if (window.LCARS_DIVISIONS) window.LCARS_DIVISIONS.endRenderPass();
    }

    // XACA-1060: a team bucket is keyed server-side on (division, project,
    // team) -- machine is NOT part of that identity, so a team running on
    // two machines (e.g. an LCARS terminal migrated m3pro -> m4-mini mid-
    // flight, or genuinely dual-homed) collapses into one misleading card
    // that can only show one machine's data. Machine attribution IS present
    // client-side on data.sessions[].hostname and data.lcars_service.hostname
    // -- these two helpers pull that attribution out and use it to fan a
    // single bucket into one card per machine. Pure/DOM-free by design so
    // they're independently testable against a saved /api/fleet payload.
    function getTeamHosts(teamData) {
        const hosts = {};
        if (teamData) {
            const sessions = teamData.sessions;
            if (sessions) {
                for (let i = 0; i < sessions.length; i++) {
                    const h = sessions[i] && sessions[i].hostname;
                    if (h) hosts[h] = true;
                }
            }
            const svc = teamData.lcars_service;
            if (svc && svc.hostname) {
                hosts[svc.hostname] = true;
            }
        }
        return Object.keys(hosts).sort();
    }

    // XACA-1060: returns [[hostname, narrowedTeamData], ...] sorted by
    // hostname, one entry per host from getTeamHosts(). A bucket with no
    // host attribution at all -- e.g. XACA-1002's idle_registered synthetic
    // bucket, which has no sessions and no lcars_service -- returns [],
    // which the createDivisionPanel call site below treats as "drop this
    // team" (see XACA-1060 comment there). Each narrowedTeamData is a
    // shallow copy; teamData itself is never mutated.
    function splitTeamByHost(teamData) {
        const hosts = getTeamHosts(teamData);
        return hosts.map(function(host) {
            const narrowed = Object.assign({}, teamData);
            narrowed.sessions = (teamData.sessions || []).filter(function(s) {
                return s && s.hostname === host;
            });
            if (teamData.lcars_service && teamData.lcars_service.hostname === host) {
                narrowed.lcars_service = teamData.lcars_service;
            } else {
                delete narrowed.lcars_service;
            }
            return [host, narrowed];
        });
    }

    function createDivisionPanel(name, data) {
        const panel = document.createElement('div');
        panel.className = 'division-container ' + getDivisionColorClass(name);
        panel.id = 'div-' + name.toLowerCase().replace(/\s+/g, '-');

        const header = document.createElement('div');
        header.className = 'division-header';
        // XACA-0989: '.division-toggle-icon' is filled in by
        // LCARS_DIVISIONS.wireDivisionToggle() below -- empty here.
        // XACA-0416-004: getDivisionTitle() falls through to `code.toUpperCase()`
        // for ANY unrecognised division code, and `division` is copied verbatim
        // from the reporter's POSTed session payload (server.js parseFleetData ->
        // resolveDivisionKey), so an unknown code arrives here as attacker-
        // influenced text, not a fixed-set label. Element content -> escapeHtml.
        // data.total_sessions is a server-side integer counter
        // (divisions[key].total_sessions++), never interpolated input -> unwrapped.
        // XACA-1060: '.division-stats-count' wraps just the count text so
        // applyMachineFilter() can rewrite it after filtering WITHOUT
        // touching '.division-toggle-icon' -- wireDivisionToggle() (XACA-0989)
        // requires that sibling span to exist and writes the chevron glyph
        // into it every pass; rewriting '.division-stats.textContent'
        // directly would silently delete it and kill collapse/expand.
        header.innerHTML = escapeHtml(getDivisionTitle(name)) +
            '<span class="division-stats"><span class="division-stats-count">' + data.total_sessions + ' Sessions</span>' +
            '<span class="division-toggle-icon" aria-hidden="true"></span></span>';
        panel.appendChild(header);

        // Add avatar grid showing active agents in this division. This is a
        // division-level roster summary, independent of the collapse state
        // (XACA-0989 scope is the per-team cards/chips only) -- it stays
        // visible in both the collapsed and expanded views.
        const avatarGrid = createDivisionAvatarGrid(name, data);
        if (avatarGrid) {
            panel.appendChild(avatarGrid);
        }

        const content = document.createElement('div');
        content.className = 'teams-grid';

        // XACA-0989: collected alongside the (unchanged) expanded cards so
        // the collapsed chip view never has to re-walk data.projects.
        const chipEntries = [];
        // XACA-1060: parallel array, index-aligned with chipEntries, recording
        // which machine each chip belongs to -- used to tag the chip row's
        // DOM children after buildChipRow() builds them (see below).
        const chipHosts = [];

        for (const projectKey in data.projects) {
            const projectData = data.projects[projectKey];
            // XACA-1002-014: LCARS terminals first, then live before
            // idle-registered, then tab_order (this skin only -- the four
            // lcars2 skins never had that tier), then alphabetical.
            // Extracted to the shared module; useTabOrder preserves this
            // skin's extra tier exactly rather than silently collapsing it
            // to lcars2's ordering.
            const teamNames = Object.keys(projectData.teams).sort(
                LCARS_TERMINAL_CARD.createTeamNameComparator(projectData.teams, { useTabOrder: true })
            );
            teamNames.forEach(function(teamName) {
                // XACA-1060: a bucket is keyed on (division, project, team) --
                // machine is not part of that identity server-side, so fan
                // this one team out into one card per machine it actually
                // has attribution for (splitTeamByHost, above).
                //
                // A team with ZERO host attribution (no sessions, no
                // lcars_service) is dropped here rather than rendered.
                // Concretely today that's XACA-1002's idle_registered
                // synthetic bucket -- registered in the team registry but
                // with no live process anywhere. This deliberately REVERSES
                // the visible ORGS effect of XACA-1002 (which added a card
                // for exactly that bucket, on purpose): that rationale is
                // superseded, not overlooked. An idle team has no host, so
                // no machine button on this new filter bar could honestly
                // claim it -- there is nothing to route the click to. Gate
                // is on the EMPTY HOST SET, never on data.idle_registered
                // directly, so a malformed hostless bucket (no sessions, no
                // lcars_service, no idle marker either) is excluded the same
                // way instead of falling through to a misleading card.
                const hostEntries = splitTeamByHost(projectData.teams[teamName]);
                if (hostEntries.length === 0) {
                    return;
                }
                hostEntries.forEach(function(hostEntry) {
                    const host = hostEntry[0];
                    const narrowedTeamData = hostEntry[1];
                    const teamCard = createTeamCard(teamName, narrowedTeamData);
                    teamCard.dataset.machineHost = host;
                    // XACA-1060-006: this host's slice of the session count,
                    // read back by applyMachineFilter() to recompute the
                    // division's '.division-stats-count' from only the
                    // currently-visible cards, without re-walking data.projects.
                    teamCard.dataset.sessionCount = String((narrowedTeamData.sessions || []).length);
                    content.appendChild(teamCard);
                    chipEntries.push([teamName, narrowedTeamData]);
                    chipHosts.push(host);
                });
            });
        }

        panel.appendChild(content);

        // XACA-0989: collapsed-by-default chip view, single shared renderer
        // (shared/js/lcars-division-collapse.js). This skin's createTeamCard
        // is richer (avatar stack) than lcars2's -- the chip renderer stays
        // agnostic to that and only needs isLcarsTerminal/getLcarsUrl.
        // Fails safe to the pre-XACA-0989 always-expanded behavior if the
        // module didn't load.
        if (window.LCARS_DIVISIONS) {
            const chipRow = window.LCARS_DIVISIONS.buildChipRow(chipEntries, {
                isLcarsTerminal: isLcarsTerminal,
                getLcarsUrl: getLcarsUrl,
                // XACA-0989-022: lcars-skin-ONLY -- this skin's createTeamCard
                // is the one that renders the Backup: row (via backupStatus,
                // fetched only in this file); lcars2's card has no such row,
                // so lcars2's call sites deliberately do NOT inject this
                // helper (see those files' buildChipRow calls, unchanged).
                getBackupAction: getBackupAction
            });
            // XACA-1060: buildChipRow() appends exactly one child per
            // chipEntries entry, in input order (see buildChipRow in
            // shared/js/lcars-division-collapse.js) -- so chipRow.children[i]
            // corresponds to chipHosts[i]. Guard the length match rather than
            // trusting that invariant blindly: a future change to
            // buildChipRow that skips or merges entries would otherwise
            // silently mis-tag chips with the wrong machine.
            if (chipRow.children.length === chipHosts.length) {
                for (let ci = 0; ci < chipRow.children.length; ci++) {
                    chipRow.children[ci].dataset.machineHost = chipHosts[ci];
                }
            }
            panel.insertBefore(chipRow, content);
            window.LCARS_DIVISIONS.wireDivisionToggle(panel, header, chipRow, content);
        }

        return panel;
    }

    function getTerminalLogoUrl(teamName, division) {
        const teamLower = teamName.toLowerCase();
        const divLower = division ? division.toLowerCase() : 'unknown';

        // Handle special filename mappings where team name differs from logo filename
        const logoNameOverrides = {
            'ios': { 'stellar': 'stellar_cartography' },
            'mainevent': { 'bridge': 'command', 'stellar': 'science', 'holodeck': 'helm', 'ops': 'comms' },
            'legal': { 'crane': 'chambers', 'shore': 'mediation', 'schmidt': 'timeline', 'chase': 'filings', 'sack': 'research', 'espenson': 'discovery' }
        };

        // Get the base division for sub-divisions
        const baseDivision = divLower.startsWith('freelance') ? 'freelance'
            : divLower.startsWith('legal') ? 'legal'
            : divLower.startsWith('medical') ? 'medical'
            : divLower;

        const logoName = (logoNameOverrides[baseDivision] && logoNameOverrides[baseDivision][teamLower])
            || teamLower;

        return '/avatars/' + baseDivision + '_' + logoName + '_logo.png';
    }

    /**
     * Get human-readable terminal display name for an agent
     */
    function getTerminalDisplayName(teamName, division) {
        const teamLower = teamName.toLowerCase();
        const divLower = division ? division.toLowerCase() : '';

        const terminalNames = {
            'academy': {
                'reno': 'Engineering Lab', 'thok': 'Training Center',
                'nahla': 'Chancellor\'s Office', 'emh': 'Medical Bay'
            },
            'ios': {
                'captain': 'Bridge', 'doctor': 'Sickbay', 'seven': 'Observation Lounge',
                'torres': 'Engineering', 'wesley': 'Holodeck', 'counselor': 'Stellar Cartography',
                'worf': 'Tactical'
            },
            'android': {
                'kirk': 'Bridge', 'mccoy': 'Sickbay', 'spock': 'Science Lab',
                'scotty': 'Engineering', 'uhura': 'Communications', 'chekov': 'Navigation',
                'sulu': 'Helm'
            },
            'firebase': {
                'sisko': 'Ops Center', 'kira': 'Sickbay', 'dax': 'Stellar Cartography',
                'obrien': 'Engineering', 'odo': 'Observation', 'bashir': 'Promenade',
                'quark': 'Holodeck'
            },
            'mainevent': {
                'bridge': 'Command', 'stellar': 'Science Lab', 'holodeck': 'Helm',
                'ops': 'Communications', 'sickbay': 'Sickbay', 'engineering': 'Engineering',
                'tactical': 'Tactical', 'helm': 'Helm'
            },
            'freelance': {
                'archer': 'Command', 'phlox': 'Sickbay', 'tpol': 'Science Lab',
                'reed': 'Tactical', 'tucker': 'Engineering', 'sato': 'Communications',
                'mayweather': 'Helm'
            },
            'command': {
                'vance': 'Admiral\'s Office', 'janeway': 'Strategic Ops',
                'ross': 'Operations Center', 'nechayev': 'Intelligence',
                'paris': 'Communications'
            },
            'dns-framework': {
                'mariner': 'Command', 'boimler': 'API Design Lab', 'tendi': 'Refactoring Bay',
                'rutherford': 'Build Lab', 'shaxs': 'Testing Range', 'ransom': 'Docs Center',
                'tana': 'Bug Bay'
            },
            'legal': {
                'crane': 'Lead Counsel', 'shore': 'Mediation Suite',
                'schmidt': 'Case Management', 'chase': 'Filing Office',
                'sack': 'Law Library', 'espenson': 'Discovery Lab'
            },
            'medical': {
                'diagnostics': 'Diagnostic Medicine', 'oncology': 'Oncology',
                'immunology': 'Immunology', 'surgery': 'Surgery',
                'neurology': 'Neurology', 'emergency': 'Emergency Medicine'
            }
        };

        const baseDivision = divLower.startsWith('freelance') ? 'freelance'
            : divLower.startsWith('legal') ? 'legal'
            : divLower.startsWith('medical') ? 'medical'
            : divLower;

        if (terminalNames[baseDivision] && terminalNames[baseDivision][teamLower]) {
            return terminalNames[baseDivision][teamLower];
        }

        // Fallback: title-case the team name
        return teamLower.charAt(0).toUpperCase() + teamLower.slice(1) + ' Terminal';
    }

    function createDivisionAvatarGrid(divisionName, divisionData) {
        const container = document.createElement('div');
        container.className = 'org-avatars';

        const activeAgents = [];

        // Collect all unique team names and their status from this division.
        // XACA-1060: one avatar per HOST a team is attributed to, via the
        // same splitTeamByHost() used to fan team cards out above -- a
        // dual-homed team needs the same per-machine granularity here as on
        // the cards/chips, or the MACHINES filter would either strand a
        // stale avatar for a now-hidden host, or hide the only avatar for a
        // team that's still live on the host that's still shown.
        for (const projectKey in divisionData.projects) {
            const projectData = divisionData.projects[projectKey];
            for (const teamName in projectData.teams) {
                const teamData = projectData.teams[teamName];
                const hostEntries = splitTeamByHost(teamData);
                hostEntries.forEach(function(hostEntry) {
                    const host = hostEntry[0];
                    const narrowedTeamData = hostEntry[1];
                    const session = narrowedTeamData.sessions && narrowedTeamData.sessions[0];
                    // Service-only host entry (lcars_service, no session on
                    // this host) -- no session means no status to badge an
                    // avatar with, same as the pre-XACA-1060 single-session
                    // behavior this mirrors.
                    if (!session) return;
                    const avatarInfo = getTeamAvatarUrl(teamName, divisionName);
                    if (avatarInfo) {
                        const status = session.machine_status || 'offline';
                        activeAgents.push({
                            name: teamName,
                            host: host,
                            avatarUrl: avatarInfo.url,
                            terminalLogoUrl: getTerminalLogoUrl(teamName, divisionName),
                            persona: avatarInfo.persona,
                            status: status,
                            isOnline: status === 'online'
                        });
                    }
                });
            }
        }

        // If no avatars found, return null
        if (activeAgents.length === 0) {
            return null;
        }

        // Add team logo as first item (circular)
        const divLower = divisionName.toLowerCase();
        const teamLogoDiv = divLower.startsWith('freelance') ? 'freelance'
            : divLower.startsWith('legal') ? 'legal'
            : divLower.startsWith('medical') ? 'medical'
            : divLower === 'dns-framework' ? 'dns'
            : divLower;
        const teamLogo = document.createElement('img');
        teamLogo.src = '/avatars/' + teamLogoDiv + '_logo.png';
        teamLogo.alt = divisionName + ' Team';
        teamLogo.className = 'org-team-logo';
        teamLogo.onerror = function() { this.style.display = 'none'; };
        container.appendChild(teamLogo);

        // Render avatar thumbnails
        activeAgents.forEach(function(agent) {
            const img = document.createElement('img');
            img.src = agent.avatarUrl;
            img.alt = agent.name;
            img.className = 'org-avatar-thumb lcars-avatar' + (agent.isOnline ? '' : ' offline');
            img.title = agent.name + ' (' + agent.status + ')';
            img.dataset.persona = agent.persona;
            // XACA-1060-006: toggled by applyMachineFilter() alongside the
            // team cards/chips this agent's slice belongs to.
            img.dataset.machineHost = agent.host;
            img.onerror = function() {
                this.style.display = 'none';
            };
            container.appendChild(img);
        });

        return container;
    }

    /**
     * Get team avatar URL from API team config (API-driven)
     * Uses team config data when available, returns null if not found
     */
    function getTeamAvatarUrl(teamName, division) {
        if (!teamName) return null;

        var divLower = division ? division.toLowerCase() : 'unknown';

        if (!teamConfig || !teamConfig.teams) return null;

        // Determine base division for avatar file path
        var baseDivision = divLower;
        if (divLower.indexOf('freelance') === 0) {
            baseDivision = 'freelance';
        } else if (divLower.indexOf('legal') === 0) {
            baseDivision = 'legal';
        } else if (divLower.indexOf('medical') === 0) {
            baseDivision = 'medical';
        }

        // Look up the correct registered team for this division
        var registeredTeamId = divisionToTeamMap[divLower];
        if (registeredTeamId) {
            var teamData = teamConfig.teams[registeredTeamId];
            if (teamData && teamData.terminals && teamData.terminals[teamName]) {
                var terminal = teamData.terminals[teamName];
                if (terminal.avatar) {
                    return {
                        url: '/avatars/' + baseDivision + '_' + terminal.avatar + '_avatar_thumb.png',
                        persona: terminal.avatar
                    };
                }
            }
        }

        // No match found — do NOT fall back to searching all teams
        // (cross-team contamination produces wrong avatars and 404 URLs)
        return null;
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
    // empty card below. Deliberately kept minimal (no avatar/backup/working-
    // item panels the session-based card below builds) -- this is a
    // degraded state, not the primary path, and this file's normal card is
    // already the richest of the five; matching that complexity here would
    // multiply the surface with no session data to actually back it.
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

        var machineDisplayName = session.hostname;
        if (cachedMachineData) {
            var machineInfo = cachedMachineData.find(function(m) { return m.hostname === session.hostname; });
            if (machineInfo && machineInfo.nickname) {
                machineDisplayName = machineInfo.nickname;
            }
        }

        var backupHtml = '';
        if (isLcars) {
            var backupStatusText = '--';
            var backupStatusClass = '';
            if (backupStatus && backupStatus.boards && session.division) {
                var teamBackup = backupStatus.boards[session.division.toLowerCase()];
                if (teamBackup) {
                    var action = teamBackup.lastAction;
                    if (action === 'backed_up') {
                        backupStatusText = 'BACKED UP';
                        backupStatusClass = 'text-online';
                    } else if (action === 'skipped') {
                        backupStatusText = 'NO CHANGES';
                        backupStatusClass = 'text-online';
                    } else if (action === 'auto-restore') {
                        backupStatusText = 'RESTORED';
                        backupStatusClass = 'text-warning';
                    } else if (action === 'error') {
                        backupStatusText = 'ERROR';
                        backupStatusClass = 'text-offline';
                    }
                }
            }
            // XACA-0416-004: SAFE, no escaping needed -- backupStatusClass and
            // backupStatusText are both fixed-set literals assigned by the
            // if/else ladder above ('BACKED UP'/'NO CHANGES'/'RESTORED'/'ERROR'
            // and the matching text-* class). Nothing from teamBackup reaches
            // this string; only `action` is read, and only to pick a branch.
            backupHtml = '<div class="session-detail"><span class="session-label">Backup:</span><span class="session-value ' + backupStatusClass + '">' + backupStatusText + '</span></div>';
        }

        var workingItemHtml = '';
        if (!isLcars && workingItems) {
            var teamWork = workingItems[name.toLowerCase()];
            if (teamWork) {
                // XACA-0416-004: workTitle/subTitle are kanban item + subitem
                // titles served by GET /api/working-items, which returns
                // activeItem.title straight off the board with no sanitising.
                // Operator-authored rather than reporter-POSTed, so lower severity
                // than the session fields -- but still free-form text reaching a
                // sink, so it gets escaped. ELEMENT CONTENT -> escapeHtml.
                //
                // ORDER MATTERS: truncate the RAW value first and escape at the
                // point of interpolation. Escaping before .substring() would let
                // the cut land inside an entity and emit broken markup like
                // '&am'. workSubitem is a pre-built fragment by the time it is
                // concatenated below, so it is NOT escaped again.
                //
                // XACA-0416 (UX finding): the cut is made by truncateChars(), not
                // .substring(). See that helper for why -- .substring() splits
                // surrogate pairs and emits U+FFFD mid-title.
                var workTitle = truncateChars(teamWork.title || teamWork.id, 30);
                var workSubitem = '';
                if (teamWork.subitem) {
                    var subTitle = truncateChars(teamWork.subitem.title || teamWork.subitem.id, 25);
                    workSubitem = ' <span class="work-subitem">(' + escapeHtml(subTitle) + ')</span>';
                }
                workingItemHtml = '<div class="session-detail working-item"><span class="session-label">Working:</span><span class="session-value text-online">' + escapeHtml(workTitle) + workSubitem + '</span></div>';
            }
        }

        // Build division key that includes project for multi-project divisions
        var divisionForAvatar = session.division;
        if (session.division === 'freelance' && session.project) {
            divisionForAvatar = 'freelance-' + session.project.replace('doublenode-', '');
        } else if (session.project && (session.division === 'legal' || session.division === 'medical')) {
            divisionForAvatar = session.division + '-' + session.project;
        }

        // Get avatar URL for this team - use FULL SIZE, not thumbnail
        var avatarInfo = getTeamAvatarUrl(name, divisionForAvatar);
        var avatarUrl = null;
        var avatarPersona = null;
        if (avatarInfo) {
            avatarUrl = avatarInfo.url.replace('_avatar_thumb.png', '_avatar.png');
            avatarPersona = avatarInfo.persona;
        }

        // Build stacked terminal logo + avatar display
        var avatarHtml = '';
        var terminalLogoUrl = getTerminalLogoUrl(name, session.division);
        var divisionClass = session.division ? 'div-' + session.division.toLowerCase() : '';
        var divDisplay = session.division ? session.division.toUpperCase() : '';
        var terminalDisplayName = getTerminalDisplayName(name, session.division);
        var avatarTooltip = avatarPersona
            ? avatarPersona.charAt(0).toUpperCase() + avatarPersona.slice(1) + ' — ' + name + ' (' + divDisplay + ')'
            : name + ' (' + divDisplay + ')';
        // XACA-0416-003: every interpolation below lands inside a QUOTED ATTRIBUTE
        // value (src=, alt=, class=, title=, data-*), so all of them use
        // escapeAttr(), never escapeHtml() -- escapeHtml leaves quotes untouched
        // and would let a value like '" onmouseover=alert(1) x="' break out of the
        // attribute. avatarTooltip is escaped here at the sink rather than where it
        // is built above, so the escaping is visible at the point of interpolation.
        avatarHtml = '<div class="team-avatar-stack">' +
            '<img src="' + escapeAttr(terminalLogoUrl) + '" alt="' + escapeAttr(name) + ' terminal" class="team-terminal-logo ' + escapeAttr(divisionClass) + '" data-terminal-name="' + escapeAttr(terminalDisplayName) + '" data-terminal-division="' + escapeAttr(divDisplay) + '" data-terminal-agent="' + escapeAttr(name) + '" onerror="this.style.display=\'none\'">' +
            (avatarUrl
                ? '<img src="' + escapeAttr(avatarUrl) + '" alt="' + escapeAttr(name) + '" title="' + escapeAttr(avatarTooltip) + '" class="team-avatar lcars-avatar ' + escapeAttr(divisionClass) + '" data-persona="' + escapeAttr(avatarPersona) + '" onerror="this.style.display=\'none\'">'
                : '') +
            '</div>';

        // XACA-0416-003: this one statement mixes BOTH output contexts, so the
        // escaper is chosen per interpolation, not per statement:
        //   element content        -> escapeHtml()
        //   quoted attribute value -> escapeAttr()
        // session.hostname appears in BOTH -- as the title="..." attribute value
        // (escapeAttr) and, via machineDisplayName, as element content
        // (escapeHtml). Using escapeHtml for the title= value would be a false
        // fix: it leaves quotes untouched, so the value would still break out.
        // `status` is left unwrapped deliberately -- it is derived
        // (session.machine_status || 'offline'), not interpolated raw; triaged
        // separately under XACA-0416-004. backupHtml and workingItemHtml are
        // pre-built HTML fragments and must NOT be escaped here (that would
        // double-escape their real markup); their own inputs are triaged in 004.
        card.innerHTML =
            '<div class="team-header">' +
                '<div class="team-name">' + escapeHtml(name) + (isLcars ? '<span class="lcars-badge">LCARS</span>' : '') + '</div>' +
                '<span class="status-indicator ' + status + '"></span>' +
            '</div>' +
            '<div class="session-info-with-avatar">' +
                avatarHtml +
                '<div class="session-info">' +
                    '<div class="session-detail"><span class="session-label">Session:</span><span class="session-value">' + escapeHtml(session.name) + '</span></div>' +
                    '<div class="session-detail"><span class="session-label">Machine:</span><span class="session-value" title="' + escapeAttr(session.hostname) + '">' + escapeHtml(machineDisplayName) + '</span></div>' +
                    // XACA-0416 UX gate: FIXED. The earlier note here claimed a
                    // numeric 0 was unreachable because "a tmux window count is >= 1
                    // for any live session". That reasoned about tmux, not about the
                    // reporter. fleet-reporter.sh:452 ends the window-count pipeline
                    // with `|| echo 0`, and line 517 emits `"windows":$windows`
                    // UNQUOTED -- so under the script's `set -o pipefail` a line that
                    // does not match `N windows` produces the JSON NUMBER 0, not a
                    // string. escapeHtml() opens with `if (!text) return ''`, which
                    // swallows numeric zero, so that case rendered a BLANK cell where
                    // the pre-XACA-0416 raw concatenation had coerced it to "0".
                    //
                    // The fix coerces at the CALL SITE rather than relaxing
                    // escapeHtml's falsy guard -- escapeHtml's body is pinned by the
                    // XACA-0990 characterization baseline in
                    // tests/xaca-0990-001-lcars-terminal-card-baseline.json and has
                    // other callers. `String(undefined)` is "undefined", which renders
                    // WORSE than blank, so null/undefined are mapped to '' explicitly
                    // and keep rendering blank; only a real 0 becomes "0".
                    '<div class="session-detail"><span class="session-label">Windows:</span><span class="session-value">' + escapeHtml(session.windows == null ? '' : String(session.windows)) + '</span></div>' +
                    '<div class="session-detail"><span class="session-label">Uptime:</span><span class="session-value">' + escapeHtml(session.uptime_display) + '</span></div>' +
                    '<div class="session-detail"><span class="session-label">Status:</span><span class="session-value text-' + status + '">' + status.toUpperCase() + '</span></div>' +
                    backupHtml +
                    workingItemHtml +
                '</div>' +
            '</div>';

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
            container.innerHTML = '<p class="empty-message">No machines detected</p>';
            return;
        }

        try {
            const sortedMachines = machines.sort(function(a, b) {
                if (a.status !== b.status) {
                    return a.status === 'online' ? -1 : 1;
                }
                return a.hostname.localeCompare(b.hostname);
            });

            sortedMachines.forEach(function(machine) {
                const item = createMachineItem(machine);
                container.appendChild(item);
            });
        } catch (error) {
            console.error('[LCARS] renderMachines error:', error);
            // XACA-0416-004: error.message is engine-generated, but V8 embeds
            // offending values in several message templates, so it is not a fixed
            // string. Element content -> escapeHtml.
            container.innerHTML = '<p class="empty-message" style="color: #ff6666;">RENDER ERROR: ' + escapeHtml(error.message) + '</p>';
        }
    }

    function createMachineItem(machine) {
        const container = document.createElement('div');
        container.className = 'machine-item-container';
        container.setAttribute('data-machine-id', machine.machine_id);

        const item = document.createElement('div');
        item.className = 'machine-row ' + machine.status;

        const machineGuid = machine.machine_id || 'N/A';
        const lastSeenRelative = formatRelativeTime(machine.last_seen);
        const firstSeenDate = machine.first_seen ? formatShortDate(machine.first_seen) : 'Unknown';
        const sparklineHtml = buildSparkline(machine.uptime_history || []);

        const machineDivisions = [];
        if (machine.sessions && machine.sessions.length > 0) {
            machine.sessions.forEach(function(session) {
                if (session.division && machineDivisions.indexOf(session.division) === -1) {
                    machineDivisions.push(session.division);
                }
            });
        }

        let backupHtml = '';
        const isBackupExpanded = expandedBackupMachineId === machine.machine_id;
        if (machineDivisions.length > 0 && backupStatus && backupStatus.boards) {
            const backupStatuses = [];
            const backupDetails = [];
            const processedBoards = [];

            function processBackupBoard(boardName, teamBackup) {
                if (processedBoards.indexOf(boardName) !== -1) return;
                processedBoards.push(boardName);

                const action = teamBackup.lastAction;
                let statusClass = 'text-offline';
                let statusText = 'ERR';
                let statusLabel = 'Error';
                if (action === 'backed_up') {
                    statusClass = 'text-online';
                    statusText = 'OK';
                    statusLabel = 'Backed Up';
                } else if (action === 'skipped') {
                    statusClass = 'text-online';
                    statusText = 'OK';
                    statusLabel = 'No Changes';
                } else if (action === 'auto-restore' || action === 'restored') {
                    statusClass = 'text-warning';
                    statusText = 'RST';
                    statusLabel = 'Restored';
                }

                const displayName = (window.LCARS_CORE && LCARS_CORE.formatBackupDisplayName) ? LCARS_CORE.formatBackupDisplayName(boardName) : boardName.toUpperCase();
                // XACA-0416-004: boardName (and therefore displayName) is a KEY of
                // the reporter-POSTed backup_status.boards object, and
                // formatBackupDisplayName() is a pass-through uppercase/prefix
                // rewrite that sanitises nothing. Element content -> escapeHtml.
                // statusClass/statusText/statusLabel are fixed-set literals chosen
                // by the if/else ladder above -> unwrapped.
                backupStatuses.push('<span class="backup-team-status"><span class="backup-team-name">' + escapeHtml(displayName) + ':</span><span class="' + statusClass + '">' + statusText + '</span></span>');

                const lastCheck = teamBackup.lastCheck ? formatBackupTime(teamBackup.lastCheck) : '--';
                const lastBackup = teamBackup.lastBackup ? formatBackupTime(teamBackup.lastBackup) : '--';
                backupDetails.push(
                    '<div class="backup-detail-row">' +
                        '<span class="backup-detail-division">' + escapeHtml(displayName) + '</span>' +
                        '<span class="backup-detail-time">' + lastBackup + '</span>' +
                        '<span class="backup-detail-check-group">' +
                            '<span class="backup-detail-status ' + statusClass + '">' + statusLabel + '</span>' +
                            '<span class="backup-detail-time">' + lastCheck + '</span>' +
                        '</span>' +
                    '</div>'
                );
            }

            machineDivisions.forEach(function(division) {
                const divLower = division.toLowerCase();
                if (backupStatus.boards[divLower]) {
                    processBackupBoard(divLower, backupStatus.boards[divLower]);
                }
                Object.keys(backupStatus.boards).forEach(function(boardName) {
                    if (boardName.startsWith(divLower + '-')) {
                        processBackupBoard(boardName, backupStatus.boards[boardName]);
                    }
                });
            });
            if (backupStatuses.length > 0) {
                backupHtml =
                    // XACA-0416-004: QUOTED ATTRIBUTE -> escapeAttr. machine_id is
                    // the reporter's own machine.machine_id from POST /api/status.
                    '<div class="machine-backup-container" data-machine-id="' + escapeAttr(machine.machine_id) + '">' +
                        '<div class="machine-backup-status clickable">' +
                            '<span class="backup-expand-indicator' + (isBackupExpanded ? ' expanded' : '') + '">▶</span>' +
                            '<span class="backup-label">BACKUP:</span>' +
                            '<span class="backup-team-grid">' + backupStatuses.join('') + '</span>' +
                        '</div>' +
                        '<div class="backup-details-panel' + (isBackupExpanded ? ' expanded' : '') + '">' +
                            '<div class="backup-details-header">' +
                                '<span class="backup-details-col">Division</span>' +
                                '<span class="backup-details-col">Last Backup</span>' +
                                '<span class="backup-details-col backup-check-group-header">Last Check</span>' +
                            '</div>' +
                            backupDetails.join('') +
                        '</div>' +
                    '</div>';
            }
        }

        const displayName = machine.nickname || machine.hostname;
        const hasNickname = !!machine.nickname;
        const isExpanded = expandedMachineId === machine.machine_id;

        // XACA-0416-004: this statement mixes BOTH output contexts, so the escaper
        // is chosen per interpolation, not per statement:
        //   element content        -> escapeHtml()
        //   quoted attribute value -> escapeAttr()
        // Untrusted here means "supplied by whatever POSTed /api/status or PUT the
        // nickname endpoint" -- the server stores machine.hostname, machine_id and
        // machine.timestamp verbatim. machine.status and machine.session_count are
        // server-DERIVED (updateMachineStatuses() writes only 'online'/'offline'/
        // 'warning'; session_count is a computed integer) and stay unwrapped.
        // backupHtml and sparklineHtml are pre-built markup fragments whose own
        // inputs are escaped at the point they were built -- escaping them here
        // would double-escape their real tags. lastSeenRelative/firstSeenDate come
        // out of formatRelativeTime()/formatShortDate(), which emit only digits and
        // fixed words, so they carry nothing from the input string.
        item.innerHTML =
            '<div class="machine-row-header">' +
                '<span class="machine-expand-indicator' + (isExpanded ? ' expanded' : '') + '">▶</span>' +
                '<span class="status-indicator ' + machine.status + '"></span>' +
                '<span class="machine-hostname">' + escapeHtml(machine.hostname) + '</span>' +
                '<span class="machine-sessions">' + machine.session_count + ' sessions</span>' +
            '</div>' +
            '<div class="machine-nickname-row">' +
                '<span class="machine-nickname-label">Nickname:</span>' +
                '<span class="machine-nickname-value' + (hasNickname ? '' : ' empty') + '" data-machine-id="' + escapeAttr(machine.machine_id) + '">' +
                    (hasNickname ? escapeHtml(machine.nickname) : 'Not set') +
                '</span>' +
                // data-current= was previously escapeHtml() -- a FALSE FIX: escapeHtml
                // is textContent->innerHTML, which per the WHATWG fragment-
                // serialization spec leaves quote characters untouched, so a nickname
                // of '" onmouseover=alert(1) x="' still broke out of the attribute.
                '<button class="nickname-edit-btn" data-machine-id="' + escapeAttr(machine.machine_id) + '" data-current="' + escapeAttr(machine.nickname || '') + '" title="Edit nickname">✎</button>' +
            '</div>' +
            '<div class="machine-guid">GUID: ' + escapeHtml(machineGuid) + '</div>' +
            backupHtml +
            '<div class="machine-row-footer">' +
                '<div class="machine-meta">' +
                    '<div class="machine-meta-item">' +
                        '<span class="machine-meta-label">Last:</span>' +
                        // machine.last_seen is `machine.timestamp || now` from the
                        // POST /api/status body -- reporter-supplied, and this is a
                        // QUOTED ATTRIBUTE, so escapeAttr, not escapeHtml.
                        '<span class="machine-meta-value last-seen-value" data-timestamp="' + escapeAttr(machine.last_seen || '') + '">' + lastSeenRelative + '</span>' +
                    '</div>' +
                    '<div class="machine-meta-item">' +
                        '<span class="machine-meta-label">Since:</span>' +
                        '<span class="machine-meta-value">' + firstSeenDate + '</span>' +
                    '</div>' +
                '</div>' +
                '<div class="uptime-sparkline">' + sparklineHtml + '</div>' +
            '</div>';

        var editBtn = item.querySelector('.nickname-edit-btn');
        if (editBtn) {
            editBtn.addEventListener('click', function(e) {
                e.stopPropagation();
                openNicknameEditor(machine.machine_id, machine.nickname || '', machine.hostname);
            });
        }

        var backupContainer = item.querySelector('.machine-backup-container');
        if (backupContainer) {
            backupContainer.addEventListener('click', function(e) {
                e.stopPropagation();
                toggleBackupPanel(machine.machine_id, backupContainer);
            });
        }

        item.addEventListener('click', function(e) {
            if (e.target.closest('button') || e.target.closest('input') || e.target.closest('.machine-backup-container')) return;
            toggleHistoryPanel(machine.machine_id, container);
        });

        container.appendChild(item);

        var historyPanel = document.createElement('div');
        historyPanel.className = 'machine-history-panel' + (isExpanded ? ' expanded' : '');
        historyPanel.innerHTML = '<div class="history-loading">Loading history...</div>';
        container.appendChild(historyPanel);

        if (isExpanded) {
            fetchAndRenderHistory(machine.machine_id, historyPanel);
        }

        return container;
    }

    // XACA-0416 (review finding 2): machineId / expandedMachineId are
    // interpolated into ATTRIBUTE SELECTORS below. This is NOT an XSS sink --
    // querySelector parses CSS, it does not create markup -- it is a
    // CORRECTNESS bug. `machine_id` comes verbatim from the reporter's POSTed
    // payload (server.js applies presence-only validation), so a value holding
    // a `"` closes the selector's quoted string early and querySelector throws
    // SyntaxError, taking out the nickname editor and the expand/collapse of
    // the history and backup panels. CSS.escape() is the standard fix and its
    // output is valid inside a quoted attribute-selector string. Used bare, no
    // polyfill: lcars-ui/js/lcars.js already calls CSS.escape() unguarded in
    // five places, and this repo ships no browserslist, no transpile step and
    // no polyfill of any kind -- a speculative guard here would be the only one
    // in the codebase.
    function toggleHistoryPanel(machineId, container) {
        var panel = container.querySelector('.machine-history-panel');
        var indicator = container.querySelector('.machine-expand-indicator');

        if (expandedMachineId === machineId) {
            expandedMachineId = null;
            panel.classList.remove('expanded');
            if (indicator) indicator.classList.remove('expanded');
        } else {
            if (expandedMachineId) {
                var prevContainer = document.querySelector('.machine-item-container[data-machine-id="' + CSS.escape(expandedMachineId) + '"]');
                if (prevContainer) {
                    var prevPanel = prevContainer.querySelector('.machine-history-panel');
                    var prevIndicator = prevContainer.querySelector('.machine-expand-indicator');
                    if (prevPanel) prevPanel.classList.remove('expanded');
                    if (prevIndicator) prevIndicator.classList.remove('expanded');
                }
            }

            expandedMachineId = machineId;
            panel.classList.add('expanded');
            if (indicator) indicator.classList.add('expanded');

            fetchAndRenderHistory(machineId, panel);
        }
    }

    function toggleBackupPanel(machineId, container) {
        var panel = container.querySelector('.backup-details-panel');
        var indicator = container.querySelector('.backup-expand-indicator');

        if (expandedBackupMachineId === machineId) {
            expandedBackupMachineId = null;
            if (panel) panel.classList.remove('expanded');
            if (indicator) indicator.classList.remove('expanded');
        } else {
            if (expandedBackupMachineId) {
                var prevContainer = document.querySelector('.machine-backup-container[data-machine-id="' + CSS.escape(expandedBackupMachineId) + '"]');
                if (prevContainer) {
                    var prevPanel = prevContainer.querySelector('.backup-details-panel');
                    var prevIndicator = prevContainer.querySelector('.backup-expand-indicator');
                    if (prevPanel) prevPanel.classList.remove('expanded');
                    if (prevIndicator) prevIndicator.classList.remove('expanded');
                }
            }

            expandedBackupMachineId = machineId;
            if (panel) panel.classList.add('expanded');
            if (indicator) indicator.classList.add('expanded');
        }
    }

    function formatBackupTime(isoString) {
        if (!isoString) return '--';
        const date = new Date(isoString);
        const now = new Date();
        const diffMs = now - date;
        const diffMin = Math.floor(diffMs / (1000 * 60));
        const diffHour = Math.floor(diffMin / 60);

        if (diffMin < 1) return 'Just now';
        if (diffMin < 60) return diffMin + 'm ago';
        if (diffHour < 24) return diffHour + 'h ago';

        const month = (date.getMonth() + 1).toString().padStart(2, '0');
        const day = date.getDate().toString().padStart(2, '0');
        const hour = date.getHours().toString().padStart(2, '0');
        const min = date.getMinutes().toString().padStart(2, '0');
        return month + '/' + day + ' ' + hour + ':' + min;
    }

    function fetchAndRenderHistory(machineId, panel) {
        panel.innerHTML = '<div class="history-loading">Loading history...</div>';

        fetch(CONFIG.apiBase + '/api/machine/' + machineId + '/history?limit=50')
            .then(function(response) {
                if (!response.ok) throw new Error('Failed to fetch history');
                return response.json();
            })
            .then(function(data) {
                renderHistoryTimeline(data.entries, panel);
            })
            .catch(function(error) {
                console.error('[LCARS] Failed to fetch history:', error);
                panel.innerHTML = '<div class="history-error">Failed to load history</div>';
            });
    }

    function renderHistoryTimeline(entries, panel) {
        if (!entries || entries.length === 0) {
            panel.innerHTML = '<div class="history-empty">No state changes recorded yet</div>';
            return;
        }

        var html = '<div class="history-timeline">';

        var groupedEntries = groupEntriesByDate(entries);

        for (var date in groupedEntries) {
            html += '<div class="history-date-group">';
            html += '<div class="history-date-header">' + date + '</div>';

            groupedEntries[date].forEach(function(entry) {
                html += renderHistoryEntry(entry);
            });

            html += '</div>';
        }

        html += '</div>';
        panel.innerHTML = html;
    }

    function groupEntriesByDate(entries) {
        var groups = {};

        entries.forEach(function(entry) {
            var date = new Date(entry.timestamp);
            var dateKey = date.toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric' });

            if (!groups[dateKey]) {
                groups[dateKey] = [];
            }
            groups[dateKey].push(entry);
        });

        return groups;
    }

    function renderHistoryEntry(entry) {
        var time = new Date(entry.timestamp).toLocaleTimeString('en-US', { hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit' });

        var icon = getEventIcon(entry.event_type);
        var colorClass = getEventColorClass(entry.event_type);

        return '<div class="history-entry ' + colorClass + '">' +
            '<span class="history-icon">' + icon + '</span>' +
            '<span class="history-time">' + time + '</span>' +
            '<span class="history-details">' + escapeHtml(entry.details) + '</span>' +
        '</div>';
    }

    function getEventIcon(eventType) {
        switch (eventType) {
            case 'status_change': return '●';
            case 'session_start': return '▶';
            case 'session_stop': return '■';
            case 'ip_change': return '⟲';
            case 'first_seen': return '★';
            case 'reconnect': return '↻';
            default: return '•';
        }
    }

    function getEventColorClass(eventType) {
        switch (eventType) {
            case 'status_change': return 'event-status';
            case 'session_start': return 'event-session-start';
            case 'session_stop': return 'event-session-stop';
            case 'ip_change': return 'event-ip-change';
            case 'first_seen': return 'event-first-seen';
            case 'reconnect': return 'event-reconnect';
            default: return 'event-default';
        }
    }

    function formatRelativeTime(isoString) {
        if (!isoString) return 'Never';
        const date = new Date(isoString);
        const now = new Date();
        const diffMs = now - date;
        const diffSec = Math.floor(diffMs / 1000);
        const diffMin = Math.floor(diffSec / 60);
        const diffHour = Math.floor(diffMin / 60);
        const diffDay = Math.floor(diffHour / 24);

        if (diffSec < 60) return diffSec + 's ago';
        if (diffMin < 60) return diffMin + 'm ago';
        if (diffHour < 24) return diffHour + 'h ago';
        return diffDay + 'd ago';
    }

    function updateLastSeenValues() {
        const elements = document.querySelectorAll('.last-seen-value');
        elements.forEach(function(el) {
            const timestamp = el.getAttribute('data-timestamp');
            if (timestamp) {
                el.textContent = formatRelativeTime(timestamp);
            }
        });
    }

    function startLastSeenTimer() {
        if (lastSeenTimer) {
            clearInterval(lastSeenTimer);
        }
        lastSeenTimer = setInterval(updateLastSeenValues, 1000);
    }

    function formatShortDate(isoString) {
        if (!isoString) return 'Unknown';
        const date = new Date(isoString);
        const month = (date.getMonth() + 1).toString().padStart(2, '0');
        const day = date.getDate().toString().padStart(2, '0');
        const hour = date.getHours().toString().padStart(2, '0');
        const min = date.getMinutes().toString().padStart(2, '0');
        return month + '/' + day + ' ' + hour + ':' + min;
    }

    function buildSparkline(history) {
        const entries = history.slice(-48);
        if (entries.length === 0) {
            return '<span class="machine-meta-label" style="font-size: 9px;">No history</span>';
        }

        let html = '';
        entries.forEach(function(entry) {
            const status = entry.status || 'online';
            const height = Math.max(4, Math.min(16, 4 + (entry.session_count || 0) / 5));
            html += '<div class="sparkline-bar ' + status + '" style="height: ' + height + 'px;"></div>';
        });
        return html;
    }

    function renderActivityLog(entries) {
        const container = document.getElementById('activity-log');
        if (!container) return;

        if (!entries || entries.length === 0) {
            container.innerHTML = '<div class="log-entry empty">No activity recorded yet</div>';
            return;
        }

        let html = '';
        entries.forEach(function(entry) {
            const typeClass = entry.type ? entry.type.toLowerCase() : 'status';
            html += '<div class="log-entry ' + typeClass + '">' + escapeHtml(entry.message) + '</div>';
        });

        container.innerHTML = html;
    }

    // XACA-0416: escaping contract for the two output contexts used by this file.
    // escapeHtml() is for ELEMENT CONTENT only — it round-trips through
    // textContent -> innerHTML, which per the WHATWG HTML fragment-serialization
    // spec escapes '&', U+00A0, '<' and '>', and DELIBERATELY LEAVES QUOTES ALONE
    // (quotes are only special inside an attribute value, not element content).
    // escapeAttr() is for QUOTED ATTRIBUTE VALUES (e.g. title="...", alt="...").
    // Using escapeHtml() on an attribute value is a FALSE FIX: a value like
    // '" onmouseover=alert(1) x="' still breaks out of the attribute because no
    // quote character was touched. Do not use these interchangeably.
    function escapeHtml(text) {
        if (!text) return '';
        const div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
    }

    function escapeAttr(text) {
        if (!text) return '';
        return String(text)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&#39;');
    }

    // XACA-0416 (review finding 1): org_color is NOT an HTML problem, and no
    // HTML escaper fixes it. It is interpolated into a CSS custom-property
    // reference -- `var(--lcars-<org_color>)` -- inside a style="..." attribute.
    // escapeAttr() stops the value breaking OUT of the attribute, but it touches
    // none of `)`, `;` or `:`, so a perfectly attribute-escaped org_color of
    // `red); background-image: url(https://attacker.example/x` still closes the
    // var() and appends attacker-chosen CSS declarations. A CSS context needs an
    // ALLOWLIST, not an escaper. A custom-property suffix is a CSS identifier, so
    // accept only identifier characters and fall back to the existing default for
    // anything else. escapeAttr() is still applied to the finished style string
    // on top of this -- that layer guards the HTML attribute, this one guards the
    // CSS inside it.
    function safeCssIdent(value, fallback) {
        var s = (value === null || value === undefined) ? '' : String(value);
        return /^[A-Za-z0-9_-]+$/.test(s) ? s : fallback;
    }

    // XACA-0416 (review finding: safeCssIdent validates SYNTAX, not EXISTENCE).
    // safeCssIdent() accepts any /^[A-Za-z0-9_-]+$/ identifier, which is the
    // right security answer -- it is what stops `red); background-image: url(...`
    // -- but it says nothing about whether `--lcars-<ident>` is a property this
    // theme actually DEFINES. A syntactically perfect but UNDEFINED token still
    // emits a declaration the browser cannot resolve, and `background:
    // var(--lcars-nosuch)` renders as no background at all.
    //
    // MEASURED, not hypothetical: data/dashboards.json gives the `finance`
    // dashboard org_color=gold, and `--lcars-gold` has NO definition in either
    // shipped theme (public/lcars/css/lcars-fleet-theme.css or
    // public/lcars2/css/lcars-fleet-theme.css) -- verified against the working
    // control `--lcars-lavender`, which IS defined in both at line 50. So that
    // sidebar link ships with an invisible background today.
    //
    // The fix is a RUNTIME EXISTENCE CHECK rather than either single-case repair
    // available (adding a --lcars-gold definition, or editing dashboards.json to
    // say `amber`): both of those fix `finance` and leave the next undefined
    // token to fail exactly the same silent way. getComputedStyle() on the root
    // element returns '' for a custom property that resolves to nothing, so one
    // lookup answers the general question.
    //
    // FAILS SAFE. If getComputedStyle is unavailable (a non-browser host, an
    // older embedded webview, the unit-test DOM stub) or throws, this returns
    // true -- i.e. keeps the CURRENT behaviour of accepting the syntactically
    // valid ident. A missing capability must never silently repaint the fleet's
    // dashboards to the fallback colour.
    //
    // Cached per ident: the sidebar renders one link per dashboard, and the
    // answer cannot change without a stylesheet reload, which reloads the page.
    var _cssTokenDefinedCache = {};

    function cssTokenIsDefined(ident) {
        if (Object.prototype.hasOwnProperty.call(_cssTokenDefinedCache, ident)) {
            return _cssTokenDefinedCache[ident];
        }
        var defined = true;
        try {
            var gcs = (typeof getComputedStyle === 'function')
                ? getComputedStyle
                : (typeof window !== 'undefined' && typeof window.getComputedStyle === 'function'
                    ? window.getComputedStyle
                    : null);
            var root = (typeof document !== 'undefined') ? document.documentElement : null;
            if (gcs && root) {
                var resolved = gcs(root).getPropertyValue('--lcars-' + ident);
                defined = String(resolved === null || resolved === undefined ? '' : resolved).trim() !== '';
            }
        } catch (e) {
            defined = true;
        }
        _cssTokenDefinedCache[ident] = defined;
        return defined;
    }

    // Two layers, in this order, because they answer different questions:
    // safeCssIdent() answers "is this SAFE to interpolate into CSS?" and
    // cssTokenIsDefined() answers "does it RESOLVE to anything?". A value that
    // fails the first never reaches the second.
    function safeOrgColorIdent(value, fallback) {
        var ident = safeCssIdent(value, fallback);
        if (ident === fallback) return ident;
        return cssTokenIsDefined(ident) ? ident : fallback;
    }

    // Extracted from the sidebar-link map callback so the emitted declaration
    // can be asserted by rendering the SHIPPED function, rather than by a test
    // re-implementing the concatenation and then proving something about its
    // own copy. Returns the style attribute VALUE; the caller still escapeAttr()s
    // it, because this is the CSS layer and that is the HTML-attribute layer.
    function dashboardLinkStyle(orgColorValue, isActive) {
        var orgColor = safeOrgColorIdent(orgColorValue, 'lavender');
        if (isActive) {
            return 'background: var(--lcars-black); color: var(--lcars-' + orgColor + ');';
        }
        return 'background: var(--lcars-' + orgColor + '); color: var(--lcars-black);';
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

    // XACA-0416 (UX finding): String.prototype.substring() cuts by UTF-16 code
    // UNIT. Any astral character -- every emoji above U+FFFF included -- occupies
    // TWO units, so a title whose 30th unit lands between the halves of a
    // surrogate pair is cut mid-character and emits a LONE SURROGATE, which the
    // browser renders as the U+FFFD replacement glyph. Reproduced at 29 ASCII
    // characters followed by one emoji. Array.from() iterates by code POINT, so
    // a pair is never split.
    //
    // SCOPE, so a pass is not read as more than it is: this makes the cut
    // CODE-POINT safe, not fully grapheme-cluster safe. A ZWJ sequence
    // (family emoji) or a combining mark can still be separated from its base at
    // the boundary; that degrades to two valid glyphs, not to a replacement
    // glyph, and full segmentation would mean Intl.Segmenter. The reported defect
    // is the replacement glyph, and this removes it.
    //
    // The length TEST moves to code points too, deliberately: comparing a
    // code-unit length against a code-point slice would truncate strings that the
    // slice then leaves untouched, appending a bare '...' to a complete title.
    //
    // ORDERING IS UNCHANGED AND LOAD-BEARING -- callers still truncate the RAW
    // value and escape at the point of interpolation. Escaping first would let
    // the cut land inside a character entity and emit '&am'.
    function truncateChars(text, limit) {
        var s = (text === null || text === undefined) ? '' : String(text);
        var chars = Array.from(s);
        return chars.length > limit ? chars.slice(0, limit).join('') + '...' : s;
    }

    // ============================================================================
    // NICKNAME EDITOR
    // ============================================================================

    function openNicknameEditor(machineId, currentNickname, hostname) {
        closeNicknameEditor();

        var valueEl = document.querySelector('.machine-nickname-value[data-machine-id="' + CSS.escape(machineId) + '"]');
        if (!valueEl) return;

        var row = valueEl.closest('.machine-nickname-row');
        if (!row) return;

        valueEl.style.display = 'none';
        var editBtn = row.querySelector('.nickname-edit-btn');
        if (editBtn) editBtn.style.display = 'none';

        var editor = document.createElement('div');
        editor.className = 'nickname-editor';
        // XACA-0416-004: value= and placeholder= are QUOTED ATTRIBUTES. Both were
        // previously escapeHtml() -- a FALSE FIX, since escapeHtml leaves quotes
        // alone. currentNickname comes from the nickname endpoint and hostname from
        // the reporter's POST /api/status payload; both are untrusted.
        editor.innerHTML =
            // XACA-0416 (UX finding, WCAG 2.1 AA 4.1.2 Name/Role/Value): the input
            // had no accessible name but its placeholder, which is the LAST resort
            // in the accessible-name computation and, worse, disappears the moment
            // the operator types -- so the field goes nameless exactly while it is
            // being edited. The two buttons carried a glyph and a title= only;
            // title is also a last-resort source and is not announced by every
            // AT/browser pairing. aria-label is authoritative for all three.
            //
            // These three aria-label values are STATIC LITERALS, so they get no
            // escaper -- adding one here would be noise that implies an untrusted
            // source that does not exist. value= and placeholder= interpolate
            // untrusted data and keep their escapeAttr().
            '<input type="text" class="nickname-input" aria-label="Machine nickname" value="' + escapeAttr(currentNickname) + '" placeholder="' + escapeAttr(hostname) + '" maxlength="32">' +
            '<button class="nickname-save-btn" title="Save" aria-label="Save machine nickname">✓</button>' +
            '<button class="nickname-cancel-btn" title="Cancel" aria-label="Cancel machine nickname edit">✗</button>';

        row.appendChild(editor);

        var input = editor.querySelector('.nickname-input');
        input.focus();
        input.select();

        var saveBtn = editor.querySelector('.nickname-save-btn');
        saveBtn.addEventListener('click', function() {
            saveNickname(machineId, input.value.trim());
        });

        var cancelBtn = editor.querySelector('.nickname-cancel-btn');
        cancelBtn.addEventListener('click', closeNicknameEditor);

        input.addEventListener('keydown', function(e) {
            if (e.key === 'Enter') {
                saveNickname(machineId, input.value.trim());
            } else if (e.key === 'Escape') {
                closeNicknameEditor();
            }
        });
    }

    function closeNicknameEditor() {
        var editor = document.querySelector('.nickname-editor');
        if (editor) {
            var row = editor.closest('.machine-nickname-row');
            editor.remove();

            if (row) {
                var valueEl = row.querySelector('.machine-nickname-value');
                var editBtn = row.querySelector('.nickname-edit-btn');
                if (valueEl) valueEl.style.display = '';
                if (editBtn) editBtn.style.display = '';
            }
        }
    }

    function saveNickname(machineId, nickname) {
        fetch(CONFIG.apiBase + '/api/machine/' + machineId + '/nickname', {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ nickname: nickname || null })
        })
        .then(function(response) {
            if (!response.ok) throw new Error('Failed to save nickname');
            return response.json();
        })
        .then(function(data) {
            console.log('[LCARS] Nickname saved:', data);

            var valueEl = document.querySelector('.machine-nickname-value[data-machine-id="' + CSS.escape(machineId) + '"]');
            if (valueEl) {
                if (data.nickname) {
                    valueEl.textContent = data.nickname;
                    valueEl.classList.remove('empty');
                } else {
                    valueEl.textContent = 'Not set';
                    valueEl.classList.add('empty');
                }
            }

            var editBtn = document.querySelector('.nickname-edit-btn[data-machine-id="' + CSS.escape(machineId) + '"]');
            if (editBtn) {
                editBtn.setAttribute('data-current', data.nickname || '');
            }

            if (cachedMachineData) {
                var machine = cachedMachineData.find(function(m) { return m.machine_id === machineId; });
                if (machine) {
                    machine.nickname = data.nickname;
                }
            }

            if (cachedDivisions) {
                renderDivisions(cachedDivisions);
            }

            closeNicknameEditor();
        })
        .catch(function(error) {
            console.error('[LCARS] Failed to save nickname:', error);
            closeNicknameEditor();
        });
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
            'freelance-doublenode-starwords': 'STARWORDS - STAR TREK: ENT',
            'freelance-doublenode-workstats': 'WORKSTATS - STAR TREK: ENT',
            'freelance-doublenode-appplanning': 'APPPLANNING - STAR TREK: ENT',
            'ios': 'IOS - STAR TREK: TNG',
            'legal': 'COPARENTING',
            'legal-coparenting': 'COPARENTING',
            'medical': 'MEDICAL - HOUSE MD',
            'medical-general': 'MEDICAL - HOUSE MD'
        };
        if (!titles[code] && code.startsWith('freelance')) {
            const suffix = code.replace('freelance-', '').toUpperCase();
            return suffix + ' - STAR TREK: ENT';
        }
        // Fallback for any legal-* variant
        if (!titles[code] && code.startsWith('legal')) {
            const suffix = code.replace('legal-', '').toUpperCase();
            return suffix || 'LEGAL';
        }
        // Fallback for any medical-* variant
        if (!titles[code] && code.startsWith('medical')) {
            return 'MEDICAL - HOUSE MD';
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
            return 'org-academy';
        }
        return window.LCARS_ORG.resolveColor(group);
    }

    function getDivisionPriority(divisionCode) {
        const code = divisionCode.toLowerCase();
        if (code.startsWith('freelance')) {
            return 100;
        }
        const priorities = {
            'command': 1,
            'android': 2,
            'firebase': 3,
            'ios': 4,
            'academy': 100,
            'dns': 100
        };
        return priorities[code] || 100;
    }

    function getDivisionColorClass(divisionCode) {
        const code = divisionCode.toLowerCase();
        const colors = {
            'ios': 'div-ios',
            'android': 'div-android',
            'firebase': 'div-firebase',
            'command': 'div-command',
            'dns': 'div-dns',
            'freelance': 'div-freelance',
            'freelance-doublenode-starwords': 'div-freelance-doublenode-starwords',
            'freelance-doublenode-workstats': 'div-freelance-doublenode-workstats',
            'freelance-doublenode-appplanning': 'div-freelance-doublenode-appplanning',
            'academy': 'div-academy',
            'medical': 'div-medical',
            'medical-general': 'div-medical'
        };
        if (!colors[code] && code.startsWith('freelance')) {
            return 'div-freelance';
        }
        if (!colors[code] && code.startsWith('medical')) {
            return 'div-medical';
        }
        return colors[code] || '';
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

    // XACA-0989-022: mirrors createTeamCard's Backup: row derivation
    // EXACTLY (same `backupStatus.boards[session.division.toLowerCase()]`
    // lookup, same `lastAction` field, same "missing = unknown, not
    // failed" fallback) so the chip's backup-health signal can never
    // disagree with the card's for the same team -- the same class of fix
    // XACA-0989-018 made for the reachability wording, applied here to
    // avoid inventing a second derivation for the same underlying data.
    // `backupStatus` is this file's module-scoped cache (populated by its
    // own separate fetch -- see its declaration near the top of this
    // file); this is a per-file closure over it, exactly like
    // getLcarsUrl/isLcarsTerminal above, not a field read off `teamData`
    // itself. Returns the raw `lastAction` value ('backed_up' / 'skipped'
    // / 'auto-restore' / 'error'), or null when there is nothing to report
    // -- the shared module decides what (if anything) to render from that,
    // so this stays a pure data lookup, not a rendering decision.
    function getBackupAction(teamData) {
        const session = teamData && teamData.sessions && teamData.sessions[0];
        if (!backupStatus || !backupStatus.boards || !session || !session.division) {
            return null;
        }
        const teamBackup = backupStatus.boards[session.division.toLowerCase()];
        return (teamBackup && teamBackup.lastAction) ? teamBackup.lastAction : null;
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
    // DASHBOARD ADMIN INTEGRATION
    // ============================================================================

    let dashboardsAdminInitialized = false;

    function initDashboardsAdmin() {
        if (dashboardsAdminInitialized) {
            console.log('[LCARS] Dashboard admin already initialized');
            return;
        }

        if (window.DASHBOARDS_UI) {
            console.log('[LCARS] Initializing dashboard admin panel...');
            DASHBOARDS_UI.init();
            dashboardsAdminInitialized = true;
        } else {
            console.warn('[LCARS] DASHBOARDS_UI not loaded');
        }
    }

    /**
     * Load dashboard links dynamically into the sidebar
     * Respects ALL FLEET visibility settings
     */
    async function loadDashboardLinks() {
        try {
            const response = await fetch(CONFIG.apiBase + '/api/dashboards');
            if (!response.ok) {
                throw new Error('HTTP ' + response.status);
            }

            const data = await response.json();
            allDashboards = data.dashboards || [];

            const container = document.querySelector('.sidebar-dashboard-links');
            if (!container) {
                console.warn('[LCARS] Sidebar dashboard links container not found');
                return;
            }

            // Find current dashboard and ALL FLEET dashboard for visibility settings
            const currentDashboard = allDashboards.find(d => d.id === CONFIG.dashboardId);
            const allFleetDashboard = allDashboards.find(d => d.id === 'all');
            const showAllFleetOn = allFleetDashboard ? (allFleetDashboard.show_all_fleet_on || []) : [];
            const visibleDashboards = currentDashboard ? currentDashboard.visible_dashboards : null;

            // Filter dashboards to show
            // Priority: visible_dashboards (if defined) > show_all_fleet_on logic > show all
            const dashboardsToShow = allDashboards.filter(function(d) {
                // Always show the current dashboard
                if (d.id === CONFIG.dashboardId) return true;

                // If current dashboard has visible_dashboards defined, use it
                if (visibleDashboards && Array.isArray(visibleDashboards)) {
                    return visibleDashboards.includes(d.id);
                }

                // Default behavior: handle 'all' dashboard visibility via show_all_fleet_on
                if (d.id === 'all') {
                    // Show if we're on 'all' dashboard OR current dashboard is in show_all_fleet_on
                    return CONFIG.dashboardId === 'all' || showAllFleetOn.includes(CONFIG.dashboardId);
                }

                // Show all other dashboards by default
                return true;
            });

            // Build links HTML with org colors
            const linksHtml = dashboardsToShow.map(function(d) {
                const isActive = d.id === CONFIG.dashboardId;
                // XACA-0416 (review finding 1): org_color reaches a CSS context,
                // not an HTML one -- see safeCssIdent()'s note. Allowlist it here;
                // escapeAttr on the finished style string below is the second layer.
                // safeOrgColorIdent() adds the third: an ident that is valid but
                // names no defined --lcars-* property falls back rather than
                // emitting an unresolvable var() (see cssTokenIsDefined()).
                const linkUrl = 'lcars-dashboard.html?dashboard=' + encodeURIComponent(d.id);
                var colorStyle = dashboardLinkStyle(d.org_color, isActive);
                // href and style are QUOTED ATTRIBUTES -> escapeAttr (escapeHtml
                // leaves quotes alone and would be a false fix). The link text is
                // ELEMENT CONTENT -> escapeHtml.
                return '<a href="' + escapeAttr(linkUrl) + '" class="sidebar-link' + (isActive ? ' active' : '') +
                       '" style="' + escapeAttr(colorStyle) + '">' + escapeHtml(String(d.name || '').toUpperCase()) + '</a>';
            }).join('');

            container.innerHTML = linksHtml;
            console.log('[LCARS] Loaded ' + dashboardsToShow.length + ' dashboard links');

            // Also populate dropdown
            populateDashboardDropdown();

        } catch (error) {
            console.warn('[LCARS] Could not load dashboard links:', error);
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
