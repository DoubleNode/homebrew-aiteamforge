//
//  app.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * Starfleet Operations Dashboard - Client Application
 * Fetches and displays fleet status data in LCARS interface
 */

// Configuration
const API_BASE = window.location.origin;
const REFRESH_INTERVAL = 60000; // 60 seconds
const STARDATE_OFFSET = 41000; // TNG era stardate

// Default fallback port (used only if a session doesn't report lcars_port)
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
 * Get the LCARS URL for a team's terminal.
 * Always derives the link from the reporting machine's hostname
 * (Tailscale MagicDNS name), which the Fleet Monitor payload carries
 * per-session. See XACA-0979 — the funnel/path-map approach was retired
 * because it hardcoded a device name that silently breaks on rename.
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

    if (!lcarsSession.hostname) {
        console.warn(`No hostname reported for LCARS session on port ${localPort}`);
        return null;
    }

    return `http://${lcarsSession.hostname}:${localPort}`;
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

// ============================================================================
// === XACA-0281: AI Engines Registry ===
// ============================================================================

const ENGINES_API = '/api/engines';

// Validation regexes — mirror server-side rules
const SLUG_RE    = /^[a-z][a-z0-9-]*$/;
const ENV_VAR_RE = /^[A-Z][A-Z0-9_]*$/;
const MAX_LEN    = 200;

// Active engine/account for modal operations
let _activeEngineSlug  = null;
let _activeAccountSlug = null;

/**
 * Fetch /api/engines and render engine cards into #engines-container.
 */
async function loadEngines() {
    const container = document.getElementById('engines-container');
    if (!container) return;

    container.innerHTML = '<div class="engines-loading">LOADING...</div>';

    try {
        const resp = await fetch(ENGINES_API);
        if (!resp.ok) throw new Error(`HTTP ${resp.status}: ${resp.statusText}`);
        const data    = await resp.json();
        const engines = data.engines || [];

        container.innerHTML = '';
        if (engines.length === 0) {
            container.innerHTML = '<div class="engines-empty">No AI engines registered.</div>';
            return;
        }
        engines.forEach(engine => container.appendChild(renderEngineCard(engine)));

    } catch (err) {
        console.error('[ENGINES] loadEngines error:', err);
        container.innerHTML = `<div class="engines-error">Error loading engines: ${escHtml(err.message)}</div>`;
    }
}

/**
 * Build a card DOM element for one engine.
 */
function renderEngineCard(engine) {
    const card = document.createElement('div');
    card.className = 'engine-card';
    card.id = `engine-card-${escHtml(engine.slug)}`;

    const header = document.createElement('div');
    header.className = 'engine-card-header';

    const nameEl = document.createElement('span');
    nameEl.className = 'engine-card-name';
    nameEl.textContent = engine.name || engine.slug;

    const addBtn = document.createElement('button');
    addBtn.className = 'btn-engines-add';
    addBtn.textContent = '+ ADD ACCOUNT';
    addBtn.addEventListener('click', () =>
        openAddAccountModal(engine.slug, engine.name || engine.slug)
    );

    header.appendChild(nameEl);
    header.appendChild(addBtn);
    card.appendChild(header);

    const body = document.createElement('div');
    body.className = 'engine-card-body';
    body.id = `engine-accounts-${engine.slug}`;

    if (!engine.accounts || engine.accounts.length === 0) {
        const empty = document.createElement('div');
        empty.className = 'engines-accounts-empty';
        empty.textContent = 'No accounts registered yet. Click + ADD ACCOUNT to define one.';
        body.appendChild(empty);
    } else {
        body.appendChild(renderAccountTable(engine));
    }

    card.appendChild(body);
    return card;
}

/**
 * Build an accounts table for one engine.
 */
function renderAccountTable(engine) {
    const wrapper = document.createElement('div');
    wrapper.className = 'engine-accounts-table-wrapper';

    const table = document.createElement('table');
    table.className = 'engine-accounts-table';
    table.innerHTML = `
        <thead><tr>
            <th>NICKNAME</th>
            <th>ACCOUNT ID</th>
            <th>ENV VAR</th>
            <th>CREATED</th>
            <th>LAST VALIDATED</th>
            <th>ACTIONS</th>
        </tr></thead>
    `;

    const tbody = document.createElement('tbody');
    engine.accounts.forEach(account =>
        tbody.appendChild(renderAccountRow(engine.slug, account))
    );
    table.appendChild(tbody);
    wrapper.appendChild(table);
    return wrapper;
}

/**
 * Build one table row for an account.
 */
function renderAccountRow(engineSlug, account) {
    const tr = document.createElement('tr');
    tr.id = `account-row-${engineSlug}-${account.slug}`;

    const acctIdDisplay = account.account_id
        ? (account.account_id.substring(0, 12) + (account.account_id.length > 12 ? '...' : ''))
        : '—';

    tr.innerHTML = `
        <td class="engine-col-nickname">${escHtml(account.nickname || '—')}</td>
        <td class="engine-col-account-id" title="${escHtml(account.account_id || '')}"><code>${escHtml(acctIdDisplay)}</code></td>
        <td class="engine-col-env-var"><code>${escHtml(account.env_var_name || '—')}</code></td>
        <td class="engine-col-created">${fmtEngineDate(account.created_at)}</td>
        <td class="engine-col-validated">${fmtEngineDate(account.last_validated_at)}</td>
        <td class="engine-col-actions"></td>
    `;

    const actionsCell = tr.querySelector('.engine-col-actions');

    const editBtn = document.createElement('button');
    editBtn.className = 'btn-engine-action btn-engine-edit';
    editBtn.textContent = 'EDIT';
    editBtn.addEventListener('click', () => openEditAccountModal(engineSlug, account));

    const deleteBtn = document.createElement('button');
    deleteBtn.className = 'btn-engine-action btn-engine-delete';
    deleteBtn.textContent = 'DELETE';
    deleteBtn.addEventListener('click', () => openDeleteConfirmModal(engineSlug, account.slug));

    actionsCell.appendChild(editBtn);
    actionsCell.appendChild(deleteBtn);
    return tr;
}

// === MODALS ===

function openAddAccountModal(engineSlug, engineName) {
    _activeEngineSlug  = engineSlug;
    _activeAccountSlug = null;

    const labelEl = document.getElementById('engines-add-engine-label');
    if (labelEl) labelEl.textContent = engineName;

    ['engines-add-slug', 'engines-add-account-id', 'engines-add-nickname', 'engines-add-env-var']
        .forEach(id => { const el = document.getElementById(id); if (el) el.value = ''; });

    clearEnginesErrors('add');
    showEnginesModal('engines-add-modal');
}

function openEditAccountModal(engineSlug, account) {
    _activeEngineSlug  = engineSlug;
    _activeAccountSlug = account.slug;

    const setVal = (id, v) => { const el = document.getElementById(id); if (el) el.value = v || ''; };
    setVal('engines-edit-slug',       account.slug);
    setVal('engines-edit-account-id', account.account_id);
    setVal('engines-edit-nickname',   account.nickname);
    setVal('engines-edit-env-var',    account.env_var_name);

    clearEnginesErrors('edit');
    showEnginesModal('engines-edit-modal');
}

async function openDeleteConfirmModal(engineSlug, accountSlug) {
    _activeEngineSlug  = engineSlug;
    _activeAccountSlug = accountSlug;

    const slugLabel  = document.getElementById('engines-delete-slug-label');
    const usageInfo  = document.getElementById('engines-delete-usage-info');
    const confirmBtn = document.getElementById('engines-delete-confirm-btn');
    const serverErr  = document.getElementById('engines-delete-server-err');

    if (slugLabel)  slugLabel.textContent = accountSlug;
    if (usageInfo)  usageInfo.innerHTML   = '<div class="engines-loading">Checking usage...</div>';
    if (confirmBtn) confirmBtn.disabled   = true;
    if (serverErr)  serverErr.style.display = 'none';

    showEnginesModal('engines-delete-modal');

    // Dry-run DELETE (no ?confirm=true)
    try {
        const resp = await fetch(
            `${ENGINES_API}/${encodeURIComponent(engineSlug)}/accounts/${encodeURIComponent(accountSlug)}`,
            { method: 'DELETE' }
        );
        const data = await resp.json();

        if (!resp.ok) {
            if (usageInfo) usageInfo.innerHTML = `<div class="engines-error">Could not check usage: ${escHtml(data.error || 'Unknown error')}</div>`;
            return;
        }

        const usage = data.usage || [];
        if (usageInfo) {
            if (usage.length === 0) {
                usageInfo.innerHTML = '<div class="engines-usage-ok">Not currently in use by any team.</div>';
            } else {
                usageInfo.innerHTML =
                    `<div class="engines-usage-warn">This account is currently used by ${usage.length} team(s):</div>` +
                    '<ul class="engines-usage-list">' +
                    usage.map(u => `<li>${escHtml(u)}</li>`).join('') +
                    '</ul>';
            }
        }
        if (confirmBtn) confirmBtn.disabled = false;

    } catch (err) {
        console.error('[ENGINES] dry-run delete error:', err);
        if (usageInfo) usageInfo.innerHTML = `<div class="engines-error">Failed to check usage: ${escHtml(err.message)}</div>`;
    }
}

// === SUBMIT ===

async function submitAddAccount() {
    const slug      = (document.getElementById('engines-add-slug')?.value       || '').trim();
    const accountId = (document.getElementById('engines-add-account-id')?.value || '').trim();
    const nickname  = (document.getElementById('engines-add-nickname')?.value   || '').trim();
    const envVar    = (document.getElementById('engines-add-env-var')?.value     || '').trim();

    clearEnginesErrors('add');

    let valid = true;
    if (!slug) {
        showEnginesFieldError('engines-add-slug-err', 'Slug is required.'); valid = false;
    } else if (!SLUG_RE.test(slug)) {
        showEnginesFieldError('engines-add-slug-err', 'Must match ^[a-z][a-z0-9-]*$ (lowercase-kebab-case).'); valid = false;
    } else if (slug.length > 64) {
        showEnginesFieldError('engines-add-slug-err', 'Max 64 characters.'); valid = false;
    }
    if (!accountId) {
        showEnginesFieldError('engines-add-account-id-err', 'Account ID is required.'); valid = false;
    } else if (accountId.length > MAX_LEN) {
        showEnginesFieldError('engines-add-account-id-err', `Max ${MAX_LEN} characters.`); valid = false;
    }
    if (!nickname) {
        showEnginesFieldError('engines-add-nickname-err', 'Nickname is required.'); valid = false;
    } else if (nickname.length > MAX_LEN) {
        showEnginesFieldError('engines-add-nickname-err', `Max ${MAX_LEN} characters.`); valid = false;
    }
    if (!envVar) {
        showEnginesFieldError('engines-add-env-var-err', 'Env var name is required.'); valid = false;
    } else if (!ENV_VAR_RE.test(envVar)) {
        showEnginesFieldError('engines-add-env-var-err', 'Must match ^[A-Z][A-Z0-9_]*$ (e.g. ANTHROPIC_API_KEY_DARREN).'); valid = false;
    }
    if (!valid) return;

    const saveBtn = document.getElementById('engines-add-save-btn');
    if (saveBtn) { saveBtn.disabled = true; saveBtn.textContent = 'SAVING...'; }

    try {
        const resp = await fetch(`${ENGINES_API}/${encodeURIComponent(_activeEngineSlug)}/accounts`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ slug, account_id: accountId, nickname, env_var_name: envVar })
        });
        const data = await resp.json();
        if (!resp.ok) {
            showEnginesServerError('engines-add-server-err', data.error || `Server error (${resp.status})`);
            return;
        }
        hideEnginesModal('engines-add-modal');
        await loadEngines();
    } catch (err) {
        console.error('[ENGINES] submitAddAccount error:', err);
        showEnginesServerError('engines-add-server-err', `Network error: ${err.message}`);
    } finally {
        if (saveBtn) { saveBtn.disabled = false; saveBtn.textContent = 'SAVE'; }
    }
}

async function submitEditAccount() {
    const accountId = (document.getElementById('engines-edit-account-id')?.value || '').trim();
    const nickname  = (document.getElementById('engines-edit-nickname')?.value   || '').trim();
    const envVar    = (document.getElementById('engines-edit-env-var')?.value    || '').trim();

    clearEnginesErrors('edit');

    let valid = true;
    if (!accountId) {
        showEnginesFieldError('engines-edit-account-id-err', 'Account ID is required.'); valid = false;
    } else if (accountId.length > MAX_LEN) {
        showEnginesFieldError('engines-edit-account-id-err', `Max ${MAX_LEN} characters.`); valid = false;
    }
    if (!nickname) {
        showEnginesFieldError('engines-edit-nickname-err', 'Nickname is required.'); valid = false;
    } else if (nickname.length > MAX_LEN) {
        showEnginesFieldError('engines-edit-nickname-err', `Max ${MAX_LEN} characters.`); valid = false;
    }
    if (!envVar) {
        showEnginesFieldError('engines-edit-env-var-err', 'Env var name is required.'); valid = false;
    } else if (!ENV_VAR_RE.test(envVar)) {
        showEnginesFieldError('engines-edit-env-var-err', 'Must match ^[A-Z][A-Z0-9_]*$ (e.g. ANTHROPIC_API_KEY_DARREN).'); valid = false;
    }
    if (!valid) return;

    const saveBtn = document.getElementById('engines-edit-save-btn');
    if (saveBtn) { saveBtn.disabled = true; saveBtn.textContent = 'SAVING...'; }

    try {
        const resp = await fetch(
            `${ENGINES_API}/${encodeURIComponent(_activeEngineSlug)}/accounts/${encodeURIComponent(_activeAccountSlug)}`,
            {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ account_id: accountId, nickname, env_var_name: envVar })
            }
        );
        const data = await resp.json();
        if (!resp.ok) {
            showEnginesServerError('engines-edit-server-err', data.error || `Server error (${resp.status})`);
            return;
        }
        hideEnginesModal('engines-edit-modal');
        await loadEngines();
    } catch (err) {
        console.error('[ENGINES] submitEditAccount error:', err);
        showEnginesServerError('engines-edit-server-err', `Network error: ${err.message}`);
    } finally {
        if (saveBtn) { saveBtn.disabled = false; saveBtn.textContent = 'SAVE'; }
    }
}

async function submitDeleteAccount() {
    const confirmBtn = document.getElementById('engines-delete-confirm-btn');
    const serverErr  = document.getElementById('engines-delete-server-err');

    if (confirmBtn) { confirmBtn.disabled = true; confirmBtn.textContent = 'DELETING...'; }
    if (serverErr)  serverErr.style.display = 'none';

    try {
        const resp = await fetch(
            `${ENGINES_API}/${encodeURIComponent(_activeEngineSlug)}/accounts/${encodeURIComponent(_activeAccountSlug)}?confirm=true`,
            { method: 'DELETE' }
        );
        const data = await resp.json();
        if (!resp.ok) {
            if (serverErr) { serverErr.textContent = data.error || `Server error (${resp.status})`; serverErr.style.display = 'block'; }
            return;
        }
        hideEnginesModal('engines-delete-modal');
        await loadEngines();
    } catch (err) {
        console.error('[ENGINES] submitDeleteAccount error:', err);
        if (serverErr) { serverErr.textContent = `Network error: ${err.message}`; serverErr.style.display = 'block'; }
    } finally {
        if (confirmBtn) { confirmBtn.disabled = false; confirmBtn.textContent = 'CONFIRM DELETE'; }
    }
}

// === MODAL / ERROR HELPERS ===

function showEnginesModal(id) {
    const el = document.getElementById(id);
    if (el) el.classList.add('active');
}

function hideEnginesModal(id) {
    const el = document.getElementById(id);
    if (el) el.classList.remove('active');
}

function showEnginesFieldError(errId, msg) {
    const el = document.getElementById(errId);
    if (!el) return;
    el.textContent = msg;
    el.style.display = 'block';
}

function showEnginesServerError(errId, msg) {
    const el = document.getElementById(errId);
    if (!el) return;
    el.textContent = msg;
    el.style.display = 'block';
}

function clearEnginesErrors(prefix) {
    const ids = prefix === 'add'
        ? ['engines-add-slug-err', 'engines-add-account-id-err', 'engines-add-nickname-err', 'engines-add-env-var-err', 'engines-add-server-err']
        : ['engines-edit-account-id-err', 'engines-edit-nickname-err', 'engines-edit-env-var-err', 'engines-edit-server-err'];
    ids.forEach(id => {
        const el = document.getElementById(id);
        if (el) { el.textContent = ''; el.style.display = 'none'; }
    });
}

function escHtml(str) {
    if (str == null) return '';
    return String(str)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
}

function fmtEngineDate(iso) {
    if (!iso) return '—';
    const d = new Date(iso);
    if (isNaN(d.getTime())) return '—';
    return d.toLocaleDateString() + ' ' + d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

// Wire up engines UI once DOM is ready
document.addEventListener('DOMContentLoaded', () => {
    // Sidebar navigation for engines section
    const enginesSidebarBtn = document.querySelector('[data-section="engines"]');
    if (enginesSidebarBtn) {
        enginesSidebarBtn.addEventListener('click', () => loadEngines());
    }

    // (XACA-0963) ENGINES REFRESH button removed; loadEngines() still
    // runs on section entry.

    // Add modal
    const addSave   = document.getElementById('engines-add-save-btn');
    const addCancel = document.getElementById('engines-add-cancel-btn');
    if (addSave)   addSave.addEventListener('click',   submitAddAccount);
    if (addCancel) addCancel.addEventListener('click', () => hideEnginesModal('engines-add-modal'));

    // Edit modal
    const editSave   = document.getElementById('engines-edit-save-btn');
    const editCancel = document.getElementById('engines-edit-cancel-btn');
    if (editSave)   editSave.addEventListener('click',   submitEditAccount);
    if (editCancel) editCancel.addEventListener('click', () => hideEnginesModal('engines-edit-modal'));

    // Delete modal
    const delConfirm = document.getElementById('engines-delete-confirm-btn');
    const delCancel  = document.getElementById('engines-delete-cancel-btn');
    if (delConfirm) delConfirm.addEventListener('click', submitDeleteAccount);
    if (delCancel)  delCancel.addEventListener('click',  () => hideEnginesModal('engines-delete-modal'));

    // Backdrop click to close
    ['engines-add-modal', 'engines-edit-modal', 'engines-delete-modal'].forEach(id => {
        const el = document.getElementById(id);
        if (el) el.addEventListener('click', e => { if (e.target === el) el.classList.remove('active'); });
    });

    // Escape to close
    document.addEventListener('keydown', e => {
        if (e.key === 'Escape') {
            document.querySelectorAll('.engines-modal.active').forEach(m => m.classList.remove('active'));
        }
    });
});

// === /XACA-0281 ===
