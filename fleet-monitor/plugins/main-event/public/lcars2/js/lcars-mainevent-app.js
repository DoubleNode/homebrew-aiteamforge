/**
 * LCARS Main Event Dashboard Application
 * Filtered view showing Main Event divisions
 *
 * Divisions: android, command, firebase, ios
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
        divisions: ['android', 'command', 'firebase', 'ios'],
        dashboardName: 'MAIN EVENT',
        emptyMessage: 'No active Main Event divisions detected'
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

    // ============================================================================
    // INITIALIZATION
    // ============================================================================

    document.addEventListener('DOMContentLoaded', function() {
        console.log('[LCARS] Main Event Dashboard initializing...');

        // Initialize LCARS core
        if (window.LCARS_CORE) {
            LCARS_CORE.init({
                candyOptions: { section: 'organizations' }
            });
        }

        // Initialize Kiosk Mode (auto-rotation on idle)
        if (window.LCARS_KIOSK) {
            LCARS_KIOSK.init();
        }

        // Initial data fetch
        fetchFleetData();

        // Set up auto-refresh
        refreshTimer = setInterval(fetchFleetData, CONFIG.refreshInterval);

        // Update stardate
        updateStardate();
        setInterval(updateStardate, 1000);

        console.log('[LCARS] Main Event Dashboard initialized');
    });

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
            const filteredData = filterData(fleetData);
            renderDashboard(filteredData);
            updateConnectionStatus(true);
        } catch (error) {
            console.error('[LCARS] Failed to fetch fleet data:', error);
            updateConnectionStatus(false);
        }
    }

    function filterData(data) {
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
            navButton.innerHTML = '<span class="org-nav-name">' + orgName + '</span>' +
                '<span class="org-nav-stats">' + divisionCount + ' Divisions • ' + totalSessions + ' Sessions</span>';

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
        panel.className = 'division-container';
        panel.id = 'div-' + name.toLowerCase().replace(/\s+/g, '-');

        const header = document.createElement('div');
        header.className = 'division-header';
        header.innerHTML = getDivisionTitle(name) +
            '<span class="division-stats">' + data.total_sessions + ' Sessions</span>';
        panel.appendChild(header);

        const content = document.createElement('div');
        content.className = 'teams-grid';

        for (const projectKey in data.projects) {
            const projectData = data.projects[projectKey];
            // Sort teams with LCARS terminals first
            const teamNames = Object.keys(projectData.teams).sort(function(a, b) {
                const aIsLcars = isLcarsTerminal(projectData.teams[a]);
                const bIsLcars = isLcarsTerminal(projectData.teams[b]);
                if (aIsLcars && !bIsLcars) return -1;
                if (!aIsLcars && bIsLcars) return 1;
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

    function createTeamCard(name, data) {
        const card = document.createElement('div');
        const isLcars = isLcarsTerminal(data);
        card.className = isLcars ? 'team-card lcars-terminal' : 'team-card';

        const session = data.sessions && data.sessions[0];
        if (!session) return card;

        const status = session.machine_status || 'offline';
        const isOnline = status === 'online';

        card.innerHTML =
            '<div class="team-header">' +
                '<div class="team-name">' + name + (isLcars ? '<span class="lcars-badge">LCARS</span>' : '') + '</div>' +
                '<span class="status-indicator ' + status + '"></span>' +
            '</div>' +
            '<div class="session-info">' +
                '<div class="session-detail"><span class="session-label">Session:</span><span class="session-value">' + session.name + '</span></div>' +
                '<div class="session-detail"><span class="session-label">Machine:</span><span class="session-value">' + session.hostname + '</span></div>' +
                '<div class="session-detail"><span class="session-label">Windows:</span><span class="session-value">' + session.windows + '</span></div>' +
                '<div class="session-detail"><span class="session-label">Uptime:</span><span class="session-value">' + session.uptime_display + '</span></div>' +
                '<div class="session-detail"><span class="session-label">Status:</span><span class="session-value text-' + status + '">' + status.toUpperCase() + '</span></div>' +
            '</div>';

        // Apply theme color to non-LCARS cards
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
            container.innerHTML = '<p class="empty-message">No machines with Main Event sessions detected</p>';
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
        const item = document.createElement('div');
        item.className = 'status-row ' + machine.status;

        item.innerHTML =
            '<span class="status-indicator ' + machine.status + '"></span>' +
            '<span class="lcars-text-sm" style="flex: 1;">' + machine.hostname + '</span>' +
            '<span class="lcars-text-xs" style="color: var(--lcars-tan);">' + machine.session_count + ' sessions</span>';

        return item;
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
        const code = divisionCode.toLowerCase();
        // Handle legal-* divisions (legal-coparenting, etc.)
        if (code.startsWith('legal')) {
            return 'LEGAL';
        }
        const groups = {
            'academy': 'DEVTEAM',
            'android': 'MAIN EVENT',
            'command': 'MAIN EVENT',
            'dns': 'DOUBLENODE',
            'firebase': 'MAIN EVENT',
            'freelance': 'DOUBLENODE',
            'ios': 'MAIN EVENT'
        };
        return groups[code] || 'UNKNOWN';
    }

    function getGroupColor(group) {
        const colors = {
            'DEVTEAM': 'org-academy',
            'DOUBLENODE': 'org-doublenode',
            'MAIN EVENT': 'org-mainevent',
            'LEGAL': 'org-legal'
        };
        return colors[group] || 'org-mainevent';
    }

    function getDivisionPriority(divisionCode) {
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
        return priorities[divisionCode.toLowerCase()] || 100;
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
    // CLEANUP
    // ============================================================================

    window.addEventListener('beforeunload', function() {
        if (refreshTimer) {
            clearInterval(refreshTimer);
        }
    });

})();
