/**
 * Starfleet Operations Dashboard - Client Application
 * Fetches and displays fleet status data in LCARS interface
 */

// Configuration
const API_BASE = window.location.origin;
const REFRESH_INTERVAL = 60000; // 60 seconds
const STARDATE_OFFSET = 41000; // TNG era stardate

// LCARS Terminal Configuration
// Tailscale Funnel configuration for external access via port 443
const TAILSCALE_HOSTNAME = 'darren.tail4637d5.ts.net';

// Map local LCARS ports to Tailscale Funnel paths
// All routes now go through port 443 with path-based routing
// This ensures access from any network (carriers block non-443 ports)
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

// Default fallback port (shouldn't be needed with proper mapping)
const LCARS_PORT = 8080;

// ============================================================================
// STATE
// ============================================================================

let fleetData = null;
let refreshTimer = null;
let teamConfigCache = null;

// ============================================================================
// INITIALIZATION
// ============================================================================

document.addEventListener('DOMContentLoaded', () => {
    console.log('Starfleet Operations Dashboard initializing...');

    // Fetch team config from API
    fetchTeamConfig();

    // Initial fetch
    fetchFleetData();

    // Set up auto-refresh
    refreshTimer = setInterval(fetchFleetData, REFRESH_INTERVAL);

    // Refresh team config every 60 seconds
    setInterval(fetchTeamConfig, 60000);

    // Update stardate
    updateStardate();
    setInterval(updateStardate, 1000);
});

// ============================================================================
// DATA FETCHING
// ============================================================================

/**
 * Fetch team configuration from API
 * Populates teamConfigCache with terminal-to-persona mappings
 */
async function fetchTeamConfig() {
    try {
        const response = await fetch(`${API_BASE}/api/team-config`);

        if (!response.ok) {
            throw new Error(`HTTP ${response.status}: ${response.statusText}`);
        }

        teamConfigCache = await response.json();
        console.log('[Fleet Monitor] Team config loaded:', Object.keys(teamConfigCache.teams || {}).length, 'teams');

    } catch (error) {
        console.warn('[Fleet Monitor] Failed to fetch team config:', error);
        // Keep existing cache or use fallback
    }
}

async function fetchFleetData() {
    try {
        const response = await fetch(`${API_BASE}/api/fleet`);

        if (!response.ok) {
            throw new Error(`HTTP ${response.status}: ${response.statusText}`);
        }

        fleetData = await response.json();
        renderDashboard(fleetData);
        updateConnectionStatus(true);

    } catch (error) {
        console.error('Failed to fetch fleet data:', error);
        updateConnectionStatus(false);
    }
}

// ============================================================================
// RENDERING
// ============================================================================

function renderDashboard(data) {
    if (!data || !data.fleet) {
        console.warn('No fleet data to render');
        return;
    }

    const { fleet, last_update } = data;

    // Update summary cards
    document.getElementById('total-machines').textContent = fleet.total_machines || 0;
    document.getElementById('online-machines').textContent = fleet.online_machines || 0;
    document.getElementById('offline-machines').textContent = fleet.offline_machines || 0;
    document.getElementById('total-sessions').textContent = fleet.total_sessions || 0;
    document.getElementById('last-update').textContent = formatTimestamp(last_update);

    // Render divisions
    renderDivisions(fleet.divisions);

    // Render machines
    renderMachines(fleet.machines);
}

function renderOrganizationNav(sortedOrgs, organizationGroups) {
    const navContainer = document.getElementById('organization-nav');
    if (!navContainer) return;

    navContainer.innerHTML = '';

    for (const orgName of sortedOrgs) {
        const divisionCount = organizationGroups[orgName].length;
        const totalSessions = organizationGroups[orgName].reduce((sum, [_, data]) => sum + data.total_sessions, 0);

        const navButton = document.createElement('button');
        navButton.className = `org-nav-button ${getGroupColor(orgName)}`;
        navButton.innerHTML = `
            <span class="org-nav-name">${orgName}</span>
            <span class="org-nav-stats">${divisionCount} Divisions • ${totalSessions} Sessions</span>
        `;

        navButton.onclick = () => {
            const targetId = `org-${orgName.toLowerCase().replace(/\s+/g, '-')}`;
            const targetElement = document.getElementById(targetId);
            if (targetElement) {
                targetElement.scrollIntoView({ behavior: 'smooth', block: 'start' });
            }
        };

        navContainer.appendChild(navButton);
    }
}

function renderDivisions(divisions) {
    const container = document.getElementById('divisions-container');
    container.innerHTML = '';

    if (!divisions || Object.keys(divisions).length === 0) {
        container.innerHTML = '<p style="text-align: center; color: var(--text-secondary); padding: 40px;">No active divisions detected</p>';
        return;
    }

    // Group divisions by organization
    const organizationGroups = {};

    for (const [divisionName, divisionData] of Object.entries(divisions)) {
        const orgGroup = getOrganizationGroup(divisionName);

        if (!organizationGroups[orgGroup]) {
            organizationGroups[orgGroup] = [];
        }

        organizationGroups[orgGroup].push([divisionName, divisionData]);
    }

    // Sort organizations and render each group
    const sortedOrgs = Object.keys(organizationGroups).sort();

    // Render organization navigation bar
    renderOrganizationNav(sortedOrgs, organizationGroups);

    for (const orgName of sortedOrgs) {
        // Create organization container
        const orgContainer = document.createElement('div');
        orgContainer.className = `organization-container ${getGroupColor(orgName)}`;
        orgContainer.id = `org-${orgName.toLowerCase().replace(/\s+/g, '-')}`;

        // Organization header
        const orgHeader = document.createElement('div');
        orgHeader.className = 'organization-header';

        const totalSessions = organizationGroups[orgName].reduce((sum, [_, data]) => sum + data.total_sessions, 0);

        orgHeader.innerHTML = `
            <span>${orgName}</span>
            <span class="organization-stats">${totalSessions} Sessions</span>
        `;
        orgContainer.appendChild(orgHeader);

        // Sort divisions within organization by priority, then by title
        const sortedDivisions = organizationGroups[orgName].sort((a, b) => {
            const priorityA = getDivisionPriority(a[0]);
            const priorityB = getDivisionPriority(b[0]);

            // Sort by priority first (lower number = higher priority)
            if (priorityA !== priorityB) {
                return priorityA - priorityB;
            }

            // Fall back to alphabetical by title
            const titleA = getDivisionTitle(a[0]);
            const titleB = getDivisionTitle(b[0]);
            return titleA.localeCompare(titleB);
        });

        // Add division mini-nav (only if more than 1 division)
        if (sortedDivisions.length > 1) {
            const divisionNav = document.createElement('div');
            divisionNav.className = 'division-mini-nav';

            for (const [divisionName, divisionData] of sortedDivisions) {
                const navButton = document.createElement('button');
                navButton.className = 'division-mini-nav-button';
                const divisionTitle = getDivisionTitle(divisionName);
                navButton.innerHTML = `
                    <span class="division-mini-nav-name">${divisionTitle}</span>
                    <span class="division-mini-nav-stats">${divisionData.total_sessions} Sessions</span>
                `;

                navButton.onclick = () => {
                    const targetId = `div-${divisionName.toLowerCase().replace(/\s+/g, '-')}`;
                    const targetElement = document.getElementById(targetId);
                    if (targetElement) {
                        targetElement.scrollIntoView({ behavior: 'smooth', block: 'start' });
                    }
                };

                divisionNav.appendChild(navButton);
            }

            orgContainer.appendChild(divisionNav);
        }

        // Add divisions
        for (const [divisionName, divisionData] of sortedDivisions) {
            const divisionPanel = createDivisionPanel(divisionName, divisionData);
            orgContainer.appendChild(divisionPanel);
        }

        container.appendChild(orgContainer);
    }
}

function createDivisionPanel(name, data) {
    const panel = document.createElement('div');
    panel.className = 'division-panel';
    panel.id = `div-${name.toLowerCase().replace(/\s+/g, '-')}`;

    // Header
    const header = document.createElement('div');
    header.className = 'division-header';
    const fullTitle = getDivisionTitle(name);
    header.innerHTML = `
        <span>${fullTitle}</span>
        <span class="division-stats">${data.total_sessions} Sessions</span>
    `;
    panel.appendChild(header);

    // Content
    const content = document.createElement('div');
    content.className = 'division-content';

    // Iterate through projects
    for (const [projectKey, projectData] of Object.entries(data.projects)) {
        const projectSection = createProjectSection(projectKey, projectData);
        content.appendChild(projectSection);
    }

    panel.appendChild(content);
    return panel;
}

function createProjectSection(projectKey, projectData) {
    const section = document.createElement('div');
    section.className = 'project-section';

    // Only show project header if it's not the default project
    if (projectKey !== '_default' && projectData.name) {
        const header = document.createElement('div');
        header.className = 'project-header';
        header.textContent = projectData.name.toUpperCase();
        section.appendChild(header);
    }

    // Teams grid
    const teamsGrid = document.createElement('div');
    teamsGrid.className = 'teams-grid';

    // Sort teams: LCARS terminals first, then alphabetically
    const sortedTeams = Object.entries(projectData.teams).sort((a, b) => {
        const aIsLcars = isLcarsTerminal(a[1]);
        const bIsLcars = isLcarsTerminal(b[1]);

        // LCARS terminals come first
        if (aIsLcars && !bIsLcars) return -1;
        if (!aIsLcars && bIsLcars) return 1;

        // Within same category, sort alphabetically
        return a[0].localeCompare(b[0]);
    });

    for (const [teamName, teamData] of sortedTeams) {
        const teamCard = createTeamCard(teamName, teamData);
        teamsGrid.appendChild(teamCard);
    }

    section.appendChild(teamsGrid);
    return section;
}

function createTeamCard(name, data) {
    const card = document.createElement('div');

    // Check if this is an LCARS terminal
    const isLcars = isLcarsTerminal(data);
    card.className = isLcars ? 'team-card lcars-terminal' : 'team-card';

    // Get first session for display (teams typically have 1 session)
    const session = data.sessions[0];
    if (!session) return card;

    const status = session.machine_status || 'offline';
    const isOnline = status === 'online';

    // Get avatar URL
    const avatarUrl = getAvatarUrl(session.division, name);
    const avatarHtml = `<img src="${avatarUrl}" alt="${name}" class="team-avatar${isLcars ? ' lcars-avatar' : ''}" onerror="this.src='/avatars/default_team_logo.svg'">`;

    // Build LCARS badge if applicable
    const lcarsBadge = isLcars ? '<span class="lcars-badge">LCARS</span>' : '';

    // Build LCARS action indicator for header (only for LCARS terminals)
    let lcarsAction = '';
    if (isLcars) {
        if (isOnline) {
            lcarsAction = '<span class="lcars-action lcars-action-open">▶ OPEN</span>';
        } else {
            lcarsAction = '<span class="lcars-action lcars-action-offline">⊘ OFFLINE</span>';
        }
    }

    card.innerHTML = `
        <div class="team-header">
            <div class="team-header-left">
                ${avatarHtml}
                <div class="team-name">${name}${lcarsBadge}</div>
            </div>
            ${lcarsAction}
            <span class="team-status ${status}"></span>
        </div>
        <div class="session-info">
            <div class="session-detail">
                <span class="session-label">Session:</span>
                <span class="session-value">${session.name}</span>
            </div>
            <div class="session-detail">
                <span class="session-label">Machine:</span>
                <span class="session-value">${session.hostname}</span>
            </div>
            <div class="session-detail">
                <span class="session-label">Windows:</span>
                <span class="session-value">${session.windows}</span>
            </div>
            <div class="session-detail">
                <span class="session-label">Uptime:</span>
                <span class="session-value">${session.uptime_display}</span>
            </div>
            <div class="session-detail">
                <span class="session-label">Status:</span>
                <span class="session-value text-${status}">${status.toUpperCase()}</span>
            </div>
        </div>
    `;

    // Make LCARS terminals clickable - navigate to LCARS page (only if online)
    if (isLcars) {
        const lcarsUrl = getLcarsUrl(data);

        if (lcarsUrl && isOnline) {
            // Machine is online - make clickable
            card.classList.add('lcars-clickable');
            card.title = `Click to open LCARS terminal: ${lcarsUrl}`;
            card.addEventListener('click', () => {
                window.open(lcarsUrl, '_blank');
            });
        } else if (lcarsUrl && !isOnline) {
            // Machine is offline - show disabled state
            card.classList.add('lcars-offline');
            card.title = `LCARS terminal unavailable - machine is ${status}`;
        }
    }

    return card;
}

function renderMachines(machines) {
    const container = document.getElementById('machines-list');
    container.innerHTML = '';

    if (!machines || machines.length === 0) {
        container.innerHTML = '<p style="text-align: center; color: var(--text-secondary); padding: 20px;">No machines detected</p>';
        return;
    }

    // Sort machines by status (online first) then by hostname
    const sortedMachines = machines.sort((a, b) => {
        if (a.status !== b.status) {
            return a.status === 'online' ? -1 : 1;
        }
        return a.hostname.localeCompare(b.hostname);
    });

    for (const machine of sortedMachines) {
        const item = createMachineItem(machine);
        container.appendChild(item);
    }
}

function createMachineItem(machine) {
    const item = document.createElement('div');
    item.className = `machine-item ${machine.status}`;

    const timeSinceLastSeen = getTimeSince(machine.last_seen);

    item.innerHTML = `
        <div class="machine-name">${machine.hostname}</div>
        <div class="machine-details">
            <div class="machine-detail">
                <span>IP Address:</span>
                <span class="machine-detail-value">${machine.ip}</span>
            </div>
            <div class="machine-detail">
                <span>OS:</span>
                <span class="machine-detail-value">${machine.os}</span>
            </div>
            <div class="machine-detail">
                <span>Status:</span>
                <span class="machine-detail-value text-${machine.status}">${machine.status.toUpperCase()}</span>
            </div>
            <div class="machine-detail">
                <span>Sessions:</span>
                <span class="machine-detail-value">${machine.session_count}</span>
            </div>
            <div class="machine-detail">
                <span>Last Seen:</span>
                <span class="machine-detail-value">${timeSinceLastSeen}</span>
            </div>
        </div>
    `;

    return item;
}

// ============================================================================
// DIVISION MAPPINGS
// ============================================================================

/**
 * Map division code to full display title
 */
function getDivisionTitle(divisionCode) {
    const code = divisionCode.toLowerCase();
    const titles = {
        'academy': 'DEVTEAM - STARFLEET ACADEMY',
        'android': 'MAIN EVENT - ANDROID - STAR TREK: TOS',
        'command': 'MAIN EVENT - STARFLEET COMMAND',
        'dns': 'DOUBLENODE - DNS FRAMEWORK - STAR TREK: LOWER DECKS',
        'firebase': 'MAIN EVENT - FIREBASE - STAR TREK: DS9',
        'freelance': 'DOUBLENODE - FREELANCE - STAR TREK: ENT',
        'ios': 'MAIN EVENT - IOS - STAR TREK: TNG',
        'legal': 'LEGAL - COPARENTING',
        'legal-coparenting': 'LEGAL - COPARENTING'
    };
    // Fallback for any legal-* variant
    if (!titles[code] && code.startsWith('legal')) {
        const suffix = code.replace('legal-', '').toUpperCase();
        return 'LEGAL - ' + (suffix || 'LEGAL');
    }
    return titles[code] || code.toUpperCase();
}

/**
 * Get organization group from division code
 */
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

/**
 * Get LCARS color for organization group
 */
function getGroupColor(group) {
    const colors = {
        'DEVTEAM': 'lcars-blue',
        'DOUBLENODE': 'lcars-purple',
        'MAIN EVENT': 'lcars-orange',
        'LEGAL': 'lcars-green'
    };
    return colors[group] || 'lcars-orange';
}

/**
 * Get sort priority for divisions within an organization
 * Lower number = higher priority (appears first)
 * Divisions not in the priority map get default priority of 100
 */
function getDivisionPriority(divisionCode) {
    const priorities = {
        // MAIN EVENT: Command → Android → Firebase → iOS
        'command': 1,
        'android': 2,
        'firebase': 3,
        'ios': 4,
        // DEVTEAM: Default alphabetical
        'academy': 100,
        // DOUBLENODE: Default alphabetical
        'dns': 100,
        'freelance': 100
    };
    return priorities[divisionCode.toLowerCase()] || 100;
}

// ============================================================================
// UTILITY FUNCTIONS
// ============================================================================

/**
 * Check if a team contains an LCARS terminal
 * LCARS terminals have "lcars" (case-insensitive) in their session name
 */
function isLcarsTerminal(teamData) {
    if (!teamData || !teamData.sessions || teamData.sessions.length === 0) {
        return false;
    }
    // Check if any session in this team has "LCARS" in the name
    return teamData.sessions.some(session =>
        session.name && session.name.toLowerCase().includes('lcars')
    );
}

/**
 * Get the LCARS URL for a team's terminal
 * Maps local LCARS ports to Tailscale Funnel paths for external access
 * All access goes through port 443 with path-based routing
 * Uses HTTPS via Tailscale Funnel
 */
function getLcarsUrl(teamData) {
    if (!teamData || !teamData.sessions || teamData.sessions.length === 0) {
        return null;
    }

    // Find the LCARS session to get its port
    const lcarsSession = teamData.sessions.find(session =>
        session.name && session.name.toLowerCase().includes('lcars')
    );

    if (!lcarsSession) {
        return null;
    }

    // Get local port from session data
    const localPort = lcarsSession.lcars_port || LCARS_PORT;

    // Map to Tailscale Funnel path
    const funnelPath = LCARS_PATH_MAP[localPort];

    if (!funnelPath) {
        // No mapping found - fall back to local HTTP URL
        console.warn(`No Tailscale Funnel mapping for port ${localPort}`);
        return `http://${lcarsSession.hostname}:${localPort}`;
    }

    // Construct HTTPS URL via Tailscale Funnel (port 443 with path routing)
    return `https://${TAILSCALE_HOSTNAME}${funnelPath}`;
}

/**
 * Get avatar URL for a team (API-driven)
 * Uses team config data when available, falls back to default avatar
 */
function getAvatarUrl(division, team) {
    if (!division || !team) return '/avatars/default_team_logo.svg';

    const divLower = division.toLowerCase();

    // Try to get avatar from team config API data
    if (teamConfigCache && teamConfigCache.teams) {
        // Search through all teams for matching terminal
        for (const [teamId, teamData] of Object.entries(teamConfigCache.teams)) {
            if (teamData.terminals && teamData.terminals[team]) {
                const terminal = teamData.terminals[team];
                const avatarCodename = terminal.avatar;

                if (avatarCodename) {
                    // Construct avatar path: /avatars/{division}_{avatar}_avatar.png
                    return `/avatars/${divLower}_${avatarCodename}_avatar.png`;
                }
            }
        }
    }

    // Fallback to default avatar if no team config data found
    console.warn(`[Fleet Monitor] No avatar data found for division="${division}", team="${team}". Using default.`);
    return '/avatars/default_team_logo.svg';
}

function updateStardate() {
    const now = new Date();
    const year = now.getFullYear();
    const start = new Date(year, 0, 0);
    const diff = now - start;
    const oneDay = 1000 * 60 * 60 * 24;
    const dayOfYear = Math.floor(diff / oneDay);

    // Calculate TNG-style stardate
    const stardate = STARDATE_OFFSET + (year - 2024) * 1000 + (dayOfYear / 365 * 1000);
    const stardateStr = stardate.toFixed(1);

    document.getElementById('stardate').textContent = `STARDATE ${stardateStr}`;
}

function formatTimestamp(timestamp) {
    if (!timestamp) return '--';

    const date = new Date(timestamp);
    const hours = String(date.getHours()).padStart(2, '0');
    const minutes = String(date.getMinutes()).padStart(2, '0');
    const seconds = String(date.getSeconds()).padStart(2, '0');

    return `${hours}:${minutes}:${seconds}`;
}

function getTimeSince(timestamp) {
    if (!timestamp) return '--';

    const now = new Date();
    const then = new Date(timestamp);
    const diffMs = now - then;
    const diffSec = Math.floor(diffMs / 1000);

    if (diffSec < 60) {
        return `${diffSec}s ago`;
    } else if (diffSec < 3600) {
        const mins = Math.floor(diffSec / 60);
        return `${mins}m ago`;
    } else if (diffSec < 86400) {
        const hours = Math.floor(diffSec / 3600);
        const mins = Math.floor((diffSec % 3600) / 60);
        return `${hours}h ${mins}m ago`;
    } else {
        const days = Math.floor(diffSec / 86400);
        return `${days}d ago`;
    }
}

function updateConnectionStatus(connected) {
    const statusText = document.getElementById('connection-status');
    const statusIndicator = document.querySelector('.footer-left .status-indicator');

    if (connected) {
        statusText.textContent = 'MONITORING ACTIVE';
        statusIndicator.className = 'status-indicator online';
    } else {
        statusText.textContent = 'CONNECTION LOST';
        statusIndicator.className = 'status-indicator offline';
    }
}

// ============================================================================
// CLEANUP
// ============================================================================

window.addEventListener('beforeunload', () => {
    if (refreshTimer) {
        clearInterval(refreshTimer);
    }
});
