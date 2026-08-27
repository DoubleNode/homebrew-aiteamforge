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
            return '<option value="lcars-dashboard.html?dashboard=' + d.id + '"' + selected + '>' + d.name.toUpperCase() + '</option>';
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

    function renderDivisions(divisions) {
        const container = document.getElementById('divisions-container');
        if (!container) return;

        container.innerHTML = '';
        // XACA-0989: divisions rebuild from scratch every poll -- reset the
        // shared module's per-pass toggle registry before repopulating it.
        if (window.LCARS_DIVISIONS) window.LCARS_DIVISIONS.beginRenderPass();

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

        // XACA-0989: refresh the Expand All / Collapse All label now that
        // this pass's division set (and each panel's initial paint) is final.
        if (window.LCARS_DIVISIONS) window.LCARS_DIVISIONS.endRenderPass();
    }

    function createDivisionPanel(name, data) {
        const panel = document.createElement('div');
        panel.className = 'division-container ' + getDivisionColorClass(name);
        panel.id = 'div-' + name.toLowerCase().replace(/\s+/g, '-');

        const header = document.createElement('div');
        header.className = 'division-header';
        // XACA-0989: '.division-toggle-icon' is filled in by
        // LCARS_DIVISIONS.wireDivisionToggle() below -- empty here.
        header.innerHTML = getDivisionTitle(name) +
            '<span class="division-stats">' + data.total_sessions + ' Sessions' +
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

        for (const projectKey in data.projects) {
            const projectData = data.projects[projectKey];
            const teamNames = Object.keys(projectData.teams).sort(function(a, b) {
                // LCARS terminals always sort first
                const aIsLcars = isLcarsTerminal(projectData.teams[a]);
                const bIsLcars = isLcarsTerminal(projectData.teams[b]);
                if (aIsLcars && !bIsLcars) return -1;
                if (!aIsLcars && bIsLcars) return 1;
                // Then sort by tab_order
                const aSession = projectData.teams[a].sessions && projectData.teams[a].sessions[0];
                const bSession = projectData.teams[b].sessions && projectData.teams[b].sessions[0];
                const aOrder = aSession && typeof aSession.tab_order === 'number' ? aSession.tab_order : 999;
                const bOrder = bSession && typeof bSession.tab_order === 'number' ? bSession.tab_order : 999;
                if (aOrder !== bOrder) return aOrder - bOrder;
                return a.localeCompare(b);
            });
            teamNames.forEach(function(teamName) {
                const teamCard = createTeamCard(teamName, projectData.teams[teamName]);
                content.appendChild(teamCard);
                chipEntries.push([teamName, projectData.teams[teamName]]);
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
                getLcarsUrl: getLcarsUrl
            });
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

        // Collect all unique team names and their status from this division
        for (const projectKey in divisionData.projects) {
            const projectData = divisionData.projects[projectKey];
            for (const teamName in projectData.teams) {
                const teamData = projectData.teams[teamName];
                const session = teamData.sessions && teamData.sessions[0];
                if (session) {
                    const avatarInfo = getTeamAvatarUrl(teamName, divisionName);
                    if (avatarInfo) {
                        const status = session.machine_status || 'offline';
                        activeAgents.push({
                            name: teamName,
                            avatarUrl: avatarInfo.url,
                            terminalLogoUrl: getTerminalLogoUrl(teamName, divisionName),
                            persona: avatarInfo.persona,
                            status: status,
                            isOnline: status === 'online'
                        });
                    }
                }
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

    function createTeamCard(name, data) {
        const card = document.createElement('div');
        const isLcars = isLcarsTerminal(data);
        card.className = isLcars ? 'team-card lcars-terminal' : 'team-card';

        const session = data.sessions && data.sessions[0];
        if (!session) {
            if (isLcars && data.lcars_service) {
                return createServiceOnlyLcarsCard(name, data.lcars_service);
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
            backupHtml = '<div class="session-detail"><span class="session-label">Backup:</span><span class="session-value ' + backupStatusClass + '">' + backupStatusText + '</span></div>';
        }

        var workingItemHtml = '';
        if (!isLcars && workingItems) {
            var teamWork = workingItems[name.toLowerCase()];
            if (teamWork) {
                var workTitle = teamWork.title || teamWork.id;
                if (workTitle.length > 30) workTitle = workTitle.substring(0, 30) + '...';
                var workSubitem = '';
                if (teamWork.subitem) {
                    var subTitle = teamWork.subitem.title || teamWork.subitem.id;
                    if (subTitle.length > 25) subTitle = subTitle.substring(0, 25) + '...';
                    workSubitem = ' <span class="work-subitem">(' + subTitle + ')</span>';
                }
                workingItemHtml = '<div class="session-detail working-item"><span class="session-label">Working:</span><span class="session-value text-online">' + workTitle + workSubitem + '</span></div>';
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
        avatarHtml = '<div class="team-avatar-stack">' +
            '<img src="' + terminalLogoUrl + '" alt="' + name + ' terminal" class="team-terminal-logo ' + divisionClass + '" data-terminal-name="' + terminalDisplayName + '" data-terminal-division="' + divDisplay + '" data-terminal-agent="' + name + '" onerror="this.style.display=\'none\'">' +
            (avatarUrl
                ? '<img src="' + avatarUrl + '" alt="' + name + '" title="' + avatarTooltip + '" class="team-avatar lcars-avatar ' + divisionClass + '" data-persona="' + avatarPersona + '" onerror="this.style.display=\'none\'">'
                : '') +
            '</div>';

        // XACA-0983-015 scope note: name/session.name/session.hostname
        // below are interpolated unescaped, same as before this ticket.
        // That is pre-existing debt already tracked and scoped for a
        // shared fix under XACA-0416 (todo, high) -- not addressed here
        // to avoid colliding with that ticket's broader sweep across
        // these same 5 files. Only the NEW createServiceOnlyLcarsCard
        // code above got escapeHtml() as part of this ticket.
        card.innerHTML =
            '<div class="team-header">' +
                '<div class="team-name">' + name + (isLcars ? '<span class="lcars-badge">LCARS</span>' : '') + '</div>' +
                '<span class="status-indicator ' + status + '"></span>' +
            '</div>' +
            '<div class="session-info-with-avatar">' +
                avatarHtml +
                '<div class="session-info">' +
                    '<div class="session-detail"><span class="session-label">Session:</span><span class="session-value">' + session.name + '</span></div>' +
                    '<div class="session-detail"><span class="session-label">Machine:</span><span class="session-value" title="' + session.hostname + '">' + machineDisplayName + '</span></div>' +
                    '<div class="session-detail"><span class="session-label">Windows:</span><span class="session-value">' + session.windows + '</span></div>' +
                    '<div class="session-detail"><span class="session-label">Uptime:</span><span class="session-value">' + session.uptime_display + '</span></div>' +
                    '<div class="session-detail"><span class="session-label">Status:</span><span class="session-value text-' + status + '">' + status.toUpperCase() + '</span></div>' +
                    backupHtml +
                    workingItemHtml +
                '</div>' +
            '</div>';

        if (session.theme_color && !isLcars) {
            card.style.borderLeft = '4px solid ' + session.theme_color;
            var teamNameEl = card.querySelector('.team-name');
            if (teamNameEl) {
                teamNameEl.style.cssText = 'color: ' + session.theme_color + ' !important;';
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
            container.innerHTML = '<p class="empty-message" style="color: #ff6666;">RENDER ERROR: ' + error.message + '</p>';
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
                backupStatuses.push('<span class="backup-team-status"><span class="backup-team-name">' + displayName + ':</span><span class="' + statusClass + '">' + statusText + '</span></span>');

                const lastCheck = teamBackup.lastCheck ? formatBackupTime(teamBackup.lastCheck) : '--';
                const lastBackup = teamBackup.lastBackup ? formatBackupTime(teamBackup.lastBackup) : '--';
                backupDetails.push(
                    '<div class="backup-detail-row">' +
                        '<span class="backup-detail-division">' + displayName + '</span>' +
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
                    '<div class="machine-backup-container" data-machine-id="' + machine.machine_id + '">' +
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

        item.innerHTML =
            '<div class="machine-row-header">' +
                '<span class="machine-expand-indicator' + (isExpanded ? ' expanded' : '') + '">▶</span>' +
                '<span class="status-indicator ' + machine.status + '"></span>' +
                '<span class="machine-hostname">' + machine.hostname + '</span>' +
                '<span class="machine-sessions">' + machine.session_count + ' sessions</span>' +
            '</div>' +
            '<div class="machine-nickname-row">' +
                '<span class="machine-nickname-label">Nickname:</span>' +
                '<span class="machine-nickname-value' + (hasNickname ? '' : ' empty') + '" data-machine-id="' + machine.machine_id + '">' +
                    (hasNickname ? escapeHtml(machine.nickname) : 'Not set') +
                '</span>' +
                '<button class="nickname-edit-btn" data-machine-id="' + machine.machine_id + '" data-current="' + escapeHtml(machine.nickname || '') + '" title="Edit nickname">✎</button>' +
            '</div>' +
            '<div class="machine-guid">GUID: ' + machineGuid + '</div>' +
            backupHtml +
            '<div class="machine-row-footer">' +
                '<div class="machine-meta">' +
                    '<div class="machine-meta-item">' +
                        '<span class="machine-meta-label">Last:</span>' +
                        '<span class="machine-meta-value last-seen-value" data-timestamp="' + (machine.last_seen || '') + '">' + lastSeenRelative + '</span>' +
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

    function toggleHistoryPanel(machineId, container) {
        var panel = container.querySelector('.machine-history-panel');
        var indicator = container.querySelector('.machine-expand-indicator');

        if (expandedMachineId === machineId) {
            expandedMachineId = null;
            panel.classList.remove('expanded');
            if (indicator) indicator.classList.remove('expanded');
        } else {
            if (expandedMachineId) {
                var prevContainer = document.querySelector('.machine-item-container[data-machine-id="' + expandedMachineId + '"]');
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
                var prevContainer = document.querySelector('.machine-backup-container[data-machine-id="' + expandedBackupMachineId + '"]');
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

    function escapeHtml(text) {
        if (!text) return '';
        const div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
    }

    // ============================================================================
    // NICKNAME EDITOR
    // ============================================================================

    function openNicknameEditor(machineId, currentNickname, hostname) {
        closeNicknameEditor();

        var valueEl = document.querySelector('.machine-nickname-value[data-machine-id="' + machineId + '"]');
        if (!valueEl) return;

        var row = valueEl.closest('.machine-nickname-row');
        if (!row) return;

        valueEl.style.display = 'none';
        var editBtn = row.querySelector('.nickname-edit-btn');
        if (editBtn) editBtn.style.display = 'none';

        var editor = document.createElement('div');
        editor.className = 'nickname-editor';
        editor.innerHTML =
            '<input type="text" class="nickname-input" value="' + escapeHtml(currentNickname) + '" placeholder="' + escapeHtml(hostname) + '" maxlength="32">' +
            '<button class="nickname-save-btn" title="Save">✓</button>' +
            '<button class="nickname-cancel-btn" title="Cancel">✗</button>';

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

            var valueEl = document.querySelector('.machine-nickname-value[data-machine-id="' + machineId + '"]');
            if (valueEl) {
                if (data.nickname) {
                    valueEl.textContent = data.nickname;
                    valueEl.classList.remove('empty');
                } else {
                    valueEl.textContent = 'Not set';
                    valueEl.classList.add('empty');
                }
            }

            var editBtn = document.querySelector('.nickname-edit-btn[data-machine-id="' + machineId + '"]');
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
    // preserves the local call sites verbatim; escapeHtml (still defined in
    // this file, it has other callers) is injected as the module has no
    // access to this scope.
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
                const orgColor = d.org_color || 'lavender';
                const linkUrl = 'lcars-dashboard.html?dashboard=' + d.id;

                var colorStyle;
                if (isActive) {
                    colorStyle = 'background: var(--lcars-black); color: var(--lcars-' + orgColor + ');';
                } else {
                    colorStyle = 'background: var(--lcars-' + orgColor + '); color: var(--lcars-black);';
                }
                return '<a href="' + linkUrl + '" class="sidebar-link' + (isActive ? ' active' : '') +
                       '" style="' + colorStyle + '">' + d.name.toUpperCase() + '</a>';
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
