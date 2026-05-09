//
//  lcars-all-app.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * LCARS All Fleet Dashboard Application
 * Complete view showing all divisions
 *
 * Divisions: all
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
        divisions: null,
        dashboardName: 'ALL FLEET',
        emptyMessage: 'No active divisions detected'
    };

    // LCARS Terminal Configuration
    const TAILSCALE_HOSTNAME = 'darren.tail4637d5.ts.net';
    const LCARS_PATH_MAP = {
        8260: '/ios',
        8280: '/android',
        8240: '/firebase',
        8203: '/academy',
        8180: '/dns',
        8505: '/freelance-doublenode-workstats',
        8717: '/freelance-doublenode-starwords',
        8413: '/freelance-doublenode-appplanning',
        8234: '/command',
        8220: '/legal',
        8230: '/legal-coparenting'
    };
    const LCARS_PORT = 8080;

    // ============================================================================
    // STATE
    // ============================================================================

    let fleetData = null;
    let refreshTimer = null;
    let lastSeenTimer = null;
    let cachedMachineData = null;  // Cache machine data for nickname lookups in ORGS tab
    let cachedDivisions = null;    // Cache divisions for re-rendering ORGS tab after nickname changes
    let expandedMachineId = null;  // Track which machine's history panel is expanded
    let expandedBackupMachineId = null;  // Track which machine's backup panel is expanded
    let backupStatus = null;       // Cache backup system status
    let teamConfig = null;         // Dynamic team configuration from board files
    let workingItems = null;       // Cache current working items per team

    // ============================================================================
    // INITIALIZATION
    // ============================================================================

    document.addEventListener('DOMContentLoaded', async function() {
        console.log('[LCARS] All Fleet Dashboard initializing...');

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

        // Fetch team configuration for dynamic organization mapping
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

        // Start "Last:" timer for real-time updates
        startLastSeenTimer();

        // Listen for refresh events from LCARS sections
        document.addEventListener('lcars:refresh', function() {
            fetchFleetData();
        });

        // Listen for section change events to initialize admin panel
        document.addEventListener('lcars:sectionChange', function(e) {
            if (e.detail && e.detail.section === 'admin') {
                initDashboardsAdmin();
            }
        });

        console.log('[LCARS] All Fleet Dashboard initialized');
    });

    // ============================================================================
    // DATA FETCHING
    // ============================================================================

    /**
     * Fetch team configuration for dynamic organization mapping
     * Teams are auto-discovered from kanban board files
     */
    async function fetchTeamConfig() {
        try {
            const response = await fetch(CONFIG.apiBase + '/api/team-config');
            if (response.ok) {
                teamConfig = await response.json();
                console.log('[LCARS] Team config loaded:', Object.keys(teamConfig.teams).length, 'teams,', teamConfig.organizations.length, 'organizations');
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
            // Also fetch backup status and working items
            await Promise.all([fetchBackupStatus(), fetchWorkingItems()]);
            const filteredData = filterData(fleetData);
            renderDashboard(filteredData);
            updateConnectionStatus(true);
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

    function filterData(data) {
        if (!data || !data.fleet) return data;

        // If no division filter configured, return data as-is
        if (!CONFIG.divisions) {
            return data;
        }

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
            last_update: data.last_update,
            activityLog: data.activityLog  // Pass through activity log
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

        // Cache machine data for nickname lookups in ORGS tab
        cachedMachineData = fleet.machines || [];

        // Cache divisions for re-rendering after nickname changes
        cachedDivisions = fleet.divisions;

        // Render divisions
        renderDivisions(fleet.divisions);

        // Render machines
        renderMachines(fleet.machines);

        // Render activity log
        renderActivityLog(data.activityLog || []);
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
            navButton.innerHTML = '<span class="org-nav-name">' + orgName + '</span>' +
                '<span class="org-nav-stats">' + divisionCount + ' Divisions • ' + totalSessions + ' Sessions</span>';

            navButton.onclick = function() {
                // Switch to organizations section first
                if (window.LCARS_CORE && LCARS_CORE.sections) {
                    LCARS_CORE.sections.switchSection('organizations');
                }
                // Scroll to target org after section switch animation completes
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

        if (!divisions || Object.keys(divisions).length === 0) {
            container.innerHTML = '<p class="empty-message">' + CONFIG.emptyMessage + '</p>';
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
            orgHeader.innerHTML = '<span class="organization-title">' + orgName + '</span>' +
                '<span class="organization-count">' + totalSessions + ' Sessions</span>';
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
    }

    function createDivisionPanel(name, data) {
        const panel = document.createElement('div');
        panel.className = 'division-container ' + getDivisionColorClass(name);
        panel.id = 'div-' + name.toLowerCase().replace(/\s+/g, '-');

        const header = document.createElement('div');
        header.className = 'division-header';
        header.innerHTML = getDivisionTitle(name) +
            '<span class="division-stats">' + data.total_sessions + ' Sessions</span>';
        panel.appendChild(header);

        // Add avatar grid showing active agents in this division
        const avatarGrid = createDivisionAvatarGrid(name, data);
        if (avatarGrid) {
            panel.appendChild(avatarGrid);
        }

        const content = document.createElement('div');
        content.className = 'teams-grid';

        for (const projectKey in data.projects) {
            const projectData = data.projects[projectKey];
            // Sort teams by tab_order (matching iTerm2 tab order)
            const teamNames = Object.keys(projectData.teams).sort(function(a, b) {
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
            });
        }

        panel.appendChild(content);
        return panel;
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

        const divLower = division ? division.toLowerCase() : 'unknown';

        // Try to get avatar from team config API data
        if (teamConfig && teamConfig.teams) {
            // Search through all teams for matching terminal
            for (const [teamId, teamData] of Object.entries(teamConfig.teams)) {
                if (teamData.terminals && teamData.terminals[teamName]) {
                    const terminal = teamData.terminals[teamName];
                    const avatarCodename = terminal.avatar;

                    if (avatarCodename) {
                        // Construct avatar path: /avatars/{division}_{avatar}_avatar_thumb.png
                        return {
                            url: '/avatars/' + divLower + '_' + avatarCodename + '_avatar_thumb.png',
                            persona: avatarCodename
                        };
                    }
                }
            }
        }

        // No avatar data found in team config
        return null;
    }

    function createTeamCard(name, data) {
        const card = document.createElement('div');
        const isLcars = isLcarsTerminal(data);
        card.className = isLcars ? 'team-card lcars-terminal' : 'team-card';

        const session = data.sessions && data.sessions[0];
        if (!session) return card;

        const status = session.machine_status || 'offline';
        const isOnline = status === 'online';

        // Look up nickname from cached machine data
        var machineDisplayName = session.hostname;
        if (cachedMachineData) {
            var machineInfo = cachedMachineData.find(function(m) { return m.hostname === session.hostname; });
            if (machineInfo && machineInfo.nickname) {
                machineDisplayName = machineInfo.nickname;
            }
        }

        // Look up backup status for this team (only for LCARS terminals)
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

        // Look up current working item for this team (only for non-LCARS terminals)
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

        // Get avatar URL for this team - use FULL SIZE, not thumbnail
        var avatarInfo = getTeamAvatarUrl(name, session.division);
        var avatarUrl = null;
        var avatarPersona = null;
        if (avatarInfo) {
            avatarUrl = avatarInfo.url.replace('_avatar_thumb.png', '_avatar.png');
            avatarPersona = avatarInfo.persona;
        }

        // Build prominent avatar display with LCARS styling
        var avatarHtml = '';
        if (avatarUrl) {
            var divisionClass = session.division ? 'div-' + session.division.toLowerCase() : '';
            avatarHtml = '<div class="team-avatar-container">' +
                '<img src="' + avatarUrl + '" alt="' + name + '" class="team-avatar lcars-avatar ' + divisionClass + '" data-persona="' + avatarPersona + '" onerror="this.style.display=\'none\'">' +
                '</div>';
        }

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

        // Apply theme color to non-LCARS session cards only
        // (LCARS terminals have orange background - need black text)
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
                card.addEventListener('click', function() {
                    window.open(lcarsUrl, '_blank');
                });
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
    }

    function createMachineItem(machine) {
        // Create container that wraps both the row and history panel
        const container = document.createElement('div');
        container.className = 'machine-item-container';
        container.setAttribute('data-machine-id', machine.machine_id);

        const item = document.createElement('div');
        item.className = 'machine-row ' + machine.status;

        // Format the machine ID (show full GUID)
        const machineGuid = machine.machine_id || 'N/A';

        // Format last seen as relative time
        const lastSeenRelative = formatRelativeTime(machine.last_seen);

        // Format first seen as date
        const firstSeenDate = machine.first_seen ? formatShortDate(machine.first_seen) : 'Unknown';

        // Build sparkline HTML
        const sparklineHtml = buildSparkline(machine.uptime_history || []);

        // Get unique divisions from sessions and lookup backup status
        const machineDivisions = [];
        if (machine.sessions && machine.sessions.length > 0) {
            machine.sessions.forEach(function(session) {
                if (session.division && machineDivisions.indexOf(session.division) === -1) {
                    machineDivisions.push(session.division);
                }
            });
        }

        // Build backup status HTML for this machine (clickable with expandable details)
        let backupHtml = '';
        const isBackupExpanded = expandedBackupMachineId === machine.machine_id;
        if (machineDivisions.length > 0 && backupStatus && backupStatus.boards) {
            const backupStatuses = [];
            const backupDetails = [];
            const processedBoards = [];

            // Helper to process a single backup board entry
            function processBackupBoard(boardName, teamBackup) {
                if (processedBoards.indexOf(boardName) !== -1) return; // Skip duplicates
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

                // Format display name (e.g., "freelance-doublenode-starwords" -> "FREELANCE-STARWORDS")
                const displayName = (window.LCARS_CORE && LCARS_CORE.formatBackupDisplayName) ? LCARS_CORE.formatBackupDisplayName(boardName) : boardName.toUpperCase();
                backupStatuses.push('<span class="backup-team-status"><span class="backup-team-name">' + displayName + ':</span><span class="' + statusClass + '">' + statusText + '</span></span>');

                // Build detailed info for expanded panel
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
                // First try exact match
                if (backupStatus.boards[divLower]) {
                    processBackupBoard(divLower, backupStatus.boards[divLower]);
                }
                // Also find all boards that start with this division (e.g., freelance-*)
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

        // Display name: nickname if set, otherwise hostname
        const displayName = machine.nickname || machine.hostname;
        const hasNickname = !!machine.nickname;

        // Check if this machine's history is expanded
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

        // Add click handler for edit button (prevent propagation)
        var editBtn = item.querySelector('.nickname-edit-btn');
        if (editBtn) {
            editBtn.addEventListener('click', function(e) {
                e.stopPropagation();
                openNicknameEditor(machine.machine_id, machine.nickname || '', machine.hostname);
            });
        }

        // Add click handler for backup panel toggle (prevent propagation to history panel)
        var backupContainer = item.querySelector('.machine-backup-container');
        if (backupContainer) {
            backupContainer.addEventListener('click', function(e) {
                e.stopPropagation();
                toggleBackupPanel(machine.machine_id, backupContainer);
            });
        }

        // Add click handler for expanding history panel
        item.addEventListener('click', function(e) {
            // Don't toggle if clicking on buttons, inputs, or backup container
            if (e.target.closest('button') || e.target.closest('input') || e.target.closest('.machine-backup-container')) return;
            toggleHistoryPanel(machine.machine_id, container);
        });

        container.appendChild(item);

        // Create history panel (hidden by default)
        var historyPanel = document.createElement('div');
        historyPanel.className = 'machine-history-panel' + (isExpanded ? ' expanded' : '');
        historyPanel.innerHTML = '<div class="history-loading">Loading history...</div>';
        container.appendChild(historyPanel);

        // If this machine is already expanded, fetch history
        if (isExpanded) {
            fetchAndRenderHistory(machine.machine_id, historyPanel);
        }

        return container;
    }

    /**
     * Toggle the history panel for a machine
     */
    function toggleHistoryPanel(machineId, container) {
        var panel = container.querySelector('.machine-history-panel');
        var indicator = container.querySelector('.machine-expand-indicator');

        if (expandedMachineId === machineId) {
            // Collapse this panel
            expandedMachineId = null;
            panel.classList.remove('expanded');
            if (indicator) indicator.classList.remove('expanded');
        } else {
            // Collapse any other expanded panel first
            if (expandedMachineId) {
                var prevContainer = document.querySelector('.machine-item-container[data-machine-id="' + expandedMachineId + '"]');
                if (prevContainer) {
                    var prevPanel = prevContainer.querySelector('.machine-history-panel');
                    var prevIndicator = prevContainer.querySelector('.machine-expand-indicator');
                    if (prevPanel) prevPanel.classList.remove('expanded');
                    if (prevIndicator) prevIndicator.classList.remove('expanded');
                }
            }

            // Expand this panel
            expandedMachineId = machineId;
            panel.classList.add('expanded');
            if (indicator) indicator.classList.add('expanded');

            // Fetch and render history
            fetchAndRenderHistory(machineId, panel);
        }
    }

    /**
     * Toggle the backup details panel for a machine
     */
    function toggleBackupPanel(machineId, container) {
        var panel = container.querySelector('.backup-details-panel');
        var indicator = container.querySelector('.backup-expand-indicator');

        if (expandedBackupMachineId === machineId) {
            // Collapse this panel
            expandedBackupMachineId = null;
            if (panel) panel.classList.remove('expanded');
            if (indicator) indicator.classList.remove('expanded');
        } else {
            // Collapse any other expanded backup panel first
            if (expandedBackupMachineId) {
                var prevContainer = document.querySelector('.machine-backup-container[data-machine-id="' + expandedBackupMachineId + '"]');
                if (prevContainer) {
                    var prevPanel = prevContainer.querySelector('.backup-details-panel');
                    var prevIndicator = prevContainer.querySelector('.backup-expand-indicator');
                    if (prevPanel) prevPanel.classList.remove('expanded');
                    if (prevIndicator) prevIndicator.classList.remove('expanded');
                }
            }

            // Expand this panel
            expandedBackupMachineId = machineId;
            if (panel) panel.classList.add('expanded');
            if (indicator) indicator.classList.add('expanded');
        }
    }

    /**
     * Format backup timestamp for display
     */
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

        // Show date for older backups
        const month = (date.getMonth() + 1).toString().padStart(2, '0');
        const day = date.getDate().toString().padStart(2, '0');
        const hour = date.getHours().toString().padStart(2, '0');
        const min = date.getMinutes().toString().padStart(2, '0');
        return month + '/' + day + ' ' + hour + ':' + min;
    }

    /**
     * Fetch history from API and render it
     */
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

    /**
     * Render history entries as a timeline
     */
    function renderHistoryTimeline(entries, panel) {
        if (!entries || entries.length === 0) {
            panel.innerHTML = '<div class="history-empty">No state changes recorded yet</div>';
            return;
        }

        var html = '<div class="history-timeline">';

        // Group entries by date
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

    /**
     * Group history entries by date
     */
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

    /**
     * Render a single history entry
     */
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

    /**
     * Get icon for event type
     */
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

    /**
     * Get CSS class for event type coloring
     */
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

    // Update all "Last:" values every second
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
        // Show last 48 entries (or fewer if not enough history)
        const entries = history.slice(-48);
        if (entries.length === 0) {
            // No history yet - show placeholder
            return '<span class="machine-meta-label" style="font-size: 9px;">No history</span>';
        }

        let html = '';
        entries.forEach(function(entry) {
            const status = entry.status || 'online';
            // Height based on session count (normalized, min 4px, max 16px)
            const height = Math.max(4, Math.min(16, 4 + (entry.session_count || 0) / 5));
            html += '<div class="sparkline-bar ' + status + '" style="height: ' + height + 'px;"></div>';
        });
        return html;
    }

    /**
     * Render activity log - server-style log display
     * Shows last 20 status updates, newest first
     */
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
            // Use pre-formatted message from server
            html += '<div class="log-entry ' + typeClass + '">' + escapeHtml(entry.message) + '</div>';
        });

        container.innerHTML = html;
    }

    /**
     * Escape HTML to prevent XSS
     */
    function escapeHtml(text) {
        if (!text) return '';
        const div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
    }

    // ============================================================================
    // NICKNAME EDITOR
    // ============================================================================

    /**
     * Open inline nickname editor
     */
    function openNicknameEditor(machineId, currentNickname, hostname) {
        // Close any existing editor
        closeNicknameEditor();

        // Find the nickname value element
        var valueEl = document.querySelector('.machine-nickname-value[data-machine-id="' + machineId + '"]');
        if (!valueEl) return;

        var row = valueEl.closest('.machine-nickname-row');
        if (!row) return;

        // Hide the value and edit button
        valueEl.style.display = 'none';
        var editBtn = row.querySelector('.nickname-edit-btn');
        if (editBtn) editBtn.style.display = 'none';

        // Create editor inline
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

        // Save handler
        var saveBtn = editor.querySelector('.nickname-save-btn');
        saveBtn.addEventListener('click', function() {
            saveNickname(machineId, input.value.trim());
        });

        // Cancel handler
        var cancelBtn = editor.querySelector('.nickname-cancel-btn');
        cancelBtn.addEventListener('click', closeNicknameEditor);

        // Enter to save, Escape to cancel
        input.addEventListener('keydown', function(e) {
            if (e.key === 'Enter') {
                saveNickname(machineId, input.value.trim());
            } else if (e.key === 'Escape') {
                closeNicknameEditor();
            }
        });
    }

    /**
     * Close nickname editor
     */
    function closeNicknameEditor() {
        var editor = document.querySelector('.nickname-editor');
        if (editor) {
            var row = editor.closest('.machine-nickname-row');
            editor.remove();

            // Show the value and edit button again
            if (row) {
                var valueEl = row.querySelector('.machine-nickname-value');
                var editBtn = row.querySelector('.nickname-edit-btn');
                if (valueEl) valueEl.style.display = '';
                if (editBtn) editBtn.style.display = '';
            }
        }
    }

    /**
     * Save nickname to server
     */
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

            // Update the UI
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

            // Update the edit button's data-current
            var editBtn = document.querySelector('.nickname-edit-btn[data-machine-id="' + machineId + '"]');
            if (editBtn) {
                editBtn.setAttribute('data-current', data.nickname || '');
            }

            // Update cached machine data with new nickname
            if (cachedMachineData) {
                var machine = cachedMachineData.find(function(m) { return m.machine_id === machineId; });
                if (machine) {
                    machine.nickname = data.nickname;
                }
            }

            // Re-render ORGS tab to reflect nickname change
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

        // Check dynamic team config first (auto-discovered from board files)
        if (teamConfig && teamConfig.teams && teamConfig.teams[code]) {
            return teamConfig.teams[code].teamName;
        }

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
            'legal-coparenting': 'COPARENTING'
        };
        // Fallback for any freelance-* variant not explicitly listed
        if (!titles[code] && code.startsWith('freelance')) {
            const suffix = code.replace('freelance-', '').toUpperCase();
            return suffix + ' - STAR TREK: ENT';
        }
        // Fallback for any legal-* variant
        if (!titles[code] && code.startsWith('legal')) {
            const suffix = code.replace('legal-', '').toUpperCase();
            return suffix || 'LEGAL';
        }
        return titles[code] || code.toUpperCase();
    }

    function getOrganizationGroup(divisionCode) {
        const code = divisionCode.toLowerCase();

        // Check dynamic team config first (auto-discovered from board files)
        if (teamConfig && teamConfig.teams && teamConfig.teams[code]) {
            return teamConfig.teams[code].organization;
        }

        // Fallback: Handle freelance-* divisions (freelance-doublenode-starwords, freelance-doublenode-workstats, etc.)
        if (code.startsWith('freelance')) {
            return 'DOUBLENODE';
        }
        // Fallback: Handle legal-* divisions (legal-coparenting, etc.)
        if (code.startsWith('legal')) {
            return 'LEGAL';
        }
        // Fallback: Handle medical-* divisions (medical-general, etc.)
        if (code.startsWith('medical')) {
            return 'MEDICAL';
        }
        // Fallback: Static mapping for backward compatibility
        const groups = {
            'academy': 'DEVTEAM',
            'android': 'MAIN EVENT',
            'command': 'MAIN EVENT',
            'dns': 'DOUBLENODE',
            'firebase': 'MAIN EVENT',
            'ios': 'MAIN EVENT'
        };
        return groups[code] || 'UNKNOWN';
    }

    function getGroupColor(group) {
        const colors = {
            'DEVTEAM': 'org-academy',
            'DOUBLENODE': 'org-doublenode',
            'MAIN EVENT': 'org-mainevent',
            'LEGAL': 'org-legal',
            'MEDICAL': 'org-medical'
        };
        return colors[group] || 'org-academy';
    }

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
            'academy': 'div-academy'
        };
        // Fallback for any freelance-* variant not explicitly listed
        if (!colors[code] && code.startsWith('freelance')) {
            return 'div-freelance';
        }
        // Fallback for any legal-* variant
        if (!colors[code] && code.startsWith('legal')) {
            return 'div-legal';
        }
        return colors[code] || '';
    }

    // ============================================================================
    // UTILITY FUNCTIONS
    // ============================================================================

    function isLcarsTerminal(teamData) {
        if (!teamData || !teamData.sessions || teamData.sessions.length === 0) {
            return false;
        }
        return teamData.sessions.some(function(session) {
            return session.name && session.name.toLowerCase().includes('lcars');
        });
    }

    function getLcarsUrl(teamData) {
        if (!teamData || !teamData.sessions || teamData.sessions.length === 0) {
            return null;
        }

        const lcarsSession = teamData.sessions.find(function(session) {
            return session.name && session.name.toLowerCase().includes('lcars');
        });

        if (!lcarsSession) return null;

        const localPort = lcarsSession.lcars_port || LCARS_PORT;
        const funnelPath = LCARS_PATH_MAP[localPort];

        if (!funnelPath) {
            return 'http://' + lcarsSession.hostname + ':' + localPort;
        }

        return 'https://' + TAILSCALE_HOSTNAME + funnelPath;
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

    /**
     * Initialize the dashboards admin panel
     * Called when admin section is shown
     */
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
     */
    async function loadDashboardLinks() {
        try {
            const response = await fetch(CONFIG.apiBase + '/api/dashboards');
            if (!response.ok) {
                throw new Error('HTTP ' + response.status);
            }

            const data = await response.json();
            const dashboards = data.dashboards || [];

            const container = document.querySelector('.sidebar-dashboard-links');
            if (!container) {
                console.warn('[LCARS] Sidebar dashboard links container not found');
                return;
            }

            // Determine current page to highlight active link
            const currentPath = window.location.pathname;
            const currentPage = window.location.pathname.split('/').pop() || 'lcars-index.html';

            // Build links HTML with org colors
            const linksHtml = dashboards.map(function(d) {
                // Check if this is the active dashboard
                const isActive = (currentPage === d.html_file) ||
                                 (currentPath === d.url_path) ||
                                 (currentPath === d.url_path + '/');
                const orgColor = d.org_color || 'lavender';
                // Apply org color as background (black for active), text color inverts for active
                var colorStyle;
                if (isActive) {
                    colorStyle = 'background: var(--lcars-black); color: var(--lcars-' + orgColor + ');';
                } else {
                    colorStyle = 'background: var(--lcars-' + orgColor + '); color: var(--lcars-black);';
                }
                return '<a href="' + d.html_file + '" class="sidebar-link' + (isActive ? ' active' : '') +
                       '" style="' + colorStyle + '">' + d.name.toUpperCase() + '</a>';
            }).join('');

            container.innerHTML = linksHtml;
            console.log('[LCARS] Loaded ' + dashboards.length + ' dashboard links');

        } catch (error) {
            console.warn('[LCARS] Could not load dashboard links:', error);
            // Keep the static links as fallback
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
